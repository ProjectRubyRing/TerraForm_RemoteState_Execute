#!/usr/bin/env bash
#===============================================================================
# terraform_remote_state_check.sh
#
# 概要:
#   S3バックエンドに保存された他チーム管理のTerraformリモートステートを、
#   terraform_remote_state データソース経由で実際に読み取り、
#   データソース定義の動作確認および output キーの検索・選択・値取得を行う。
#
# 対象環境: RHEL9 (EC2), bash 5.x, Terraform 1.x, AWS CLI v2, jq
#
# 使い方: ./terraform_remote_state_check.sh --help
#===============================================================================
set -euo pipefail

#-------------------------------------------------------------------------------
# 定数・グローバル変数
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly EXIT_OK=0
readonly EXIT_PARAM_ERROR=2
readonly EXIT_AUTH_ERROR=3
readonly EXIT_PERM_ERROR=4
readonly EXIT_SWITCHBACK_ERROR=5
readonly EXIT_TERRAFORM_ERROR=6
readonly EXIT_GENERIC_ERROR=1

# コマンドラインパラメータ(既定値)
BUCKET=""
STATE_KEY=""
REGION=""
DATA_SOURCE_NAME="remote_state"
OUTPUT_KEY=""
SEARCH_STRING=""
ROLE_ARN=""
EXTERNAL_ID=""
AWS_PROFILE_NAME=""
TF_DATA_SOURCE_FILE=""
SWITCHBACK_SHELL_PATH=""
AUTO_SWITCHBACK="false"
COMMON_SH_PATH=""
DEBUG="false"
KEEP_WORKDIR="false"

# 内部状態
WORKDIR=""
TF_VERSION=""
SWITCHBACK_EXECUTED="false"

# Terraform を非対話モードで実行する
export TF_IN_AUTOMATION=1
export TF_INPUT=0

#===============================================================================
# 共通関数 (Codecommit_Git_Tags_S3_Upload の common.sh 相当の内蔵実装)
# --common-sh-path で外部 common.sh を指定した場合、同名関数は上書きされる。
#===============================================================================

#--- ログ出力関数 --------------------------------------------------------------
log_info() {
    printf '[%s] [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_warn() {
    printf '[%s] [WARN]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

#--- エラー出力関数 ------------------------------------------------------------
log_error() {
    printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        printf '[%s] [DEBUG] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}

#--- 異常終了関数 --------------------------------------------------------------
# usage: die <exit_code> <message...>
die() {
    local code="$1"
    shift
    log_error "$@"
    exit "${code}"
}

#--- コマンド存在確認関数 ------------------------------------------------------
check_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "${EXIT_GENERIC_ERROR}" "必須コマンド '${cmd}' が見つかりません。インストールしてから再実行してください。"
    fi
    log_debug "コマンド確認 OK: ${cmd} ($(command -v "${cmd}"))"
}

#--- 必須パラメータ確認関数 ----------------------------------------------------
# usage: require_param <変数値> <オプション名> <説明>
require_param() {
    local value="$1"
    local opt_name="$2"
    local desc="$3"
    if [[ -z "${value}" ]]; then
        die "${EXIT_PARAM_ERROR}" "必須パラメータが不足しています: ${opt_name} (${desc})。--help で使用方法を確認してください。"
    fi
}

#--- AWS CLI 実行ヘルパー(プロファイル指定を一元化) --------------------------
aws_cli() {
    if [[ -n "${AWS_PROFILE_NAME}" ]]; then
        aws --profile "${AWS_PROFILE_NAME}" "$@"
    else
        aws "$@"
    fi
}

#--- AWS認証確認関数 -----------------------------------------------------------
# aws login --remote による認証が有効かを aws sts get-caller-identity で実確認する。
check_aws_auth() {
    log_info "AWS認証状態を確認しています (aws sts get-caller-identity) ..."
    local out
    if ! out="$(aws_cli sts get-caller-identity --output json 2>&1)"; then
        log_debug "sts get-caller-identity 失敗: ${out}"
        die "${EXIT_AUTH_ERROR}" \
            "aws login --remote による認証が完了していない、または認証期限が切れています。aws login --remote を実行してから再度実行してください。"
    fi
    # アカウントIDとARNのみ表示(トークン等の秘密情報は出力しない)
    local account arn
    account="$(printf '%s' "${out}" | jq -r '.Account // "unknown"')"
    arn="$(printf '%s' "${out}" | jq -r '.Arn // "unknown"')"
    log_info "AWS認証 OK (Account: ${account}, Arn: ${arn})"
    return 0
}

#--- 権限確認関数 --------------------------------------------------------------
# リモートステート読み取りに必要な AWS 操作権限を実際の API 呼び出しで確認する。
# 戻り値: 0=権限あり, 1=権限不足, それ以外の致命的問題は die する。
check_aws_permission() {
    local err

    if [[ -n "${ROLE_ARN}" ]]; then
        # assume role 経由でステートを読む構成の場合、assume-role 可否を確認する
        log_info "assume role の実行可否を確認しています (Role ARN: ${ROLE_ARN}) ..."
        local assume_args=(sts assume-role
            --role-arn "${ROLE_ARN}"
            --role-session-name "tfrs-check-$$"
            --duration-seconds 900
            --output json)
        if [[ -n "${EXTERNAL_ID}" ]]; then
            assume_args+=(--external-id "${EXTERNAL_ID}")
        fi
        # 認証情報(Credentials)は表示・保存しない。成否のみ判定する。
        if ! err="$(aws_cli "${assume_args[@]}" 2>&1 >/dev/null)"; then
            log_debug "assume-role 失敗: ${err}"
            if grep -qiE 'AccessDenied|not authorized' <<<"${err}"; then
                log_warn "現在の操作権限では指定 Role への assume role が許可されていません。"
                return 1
            fi
            if grep -qiE 'ExpiredToken|InvalidClientTokenId' <<<"${err}"; then
                die "${EXIT_AUTH_ERROR}" \
                    "aws login --remote による認証が完了していない、または認証期限が切れています。aws login --remote を実行してから再度実行してください。"
            fi
            log_warn "assume role の確認に失敗しました: ${err}"
            return 1
        fi
        log_info "assume role 権限確認 OK"
        return 0
    fi

    # role を使わない場合は、対象 S3 オブジェクトへの直接アクセス権限を確認する
    log_info "S3 リモートステートへのアクセス権限を確認しています (s3://${BUCKET}/${STATE_KEY}) ..."
    if ! err="$(aws_cli s3api head-object \
                    --bucket "${BUCKET}" \
                    --key "${STATE_KEY}" \
                    --region "${REGION}" 2>&1 >/dev/null)"; then
        log_debug "head-object 失敗: ${err}"
        if grep -qiE '404|Not Found|NoSuchKey' <<<"${err}"; then
            die "${EXIT_GENERIC_ERROR}" \
                "S3 バケット '${BUCKET}' にステートファイル '${STATE_KEY}' が存在しません。--bucket / --state-key の指定を確認してください。"
        fi
        if grep -qiE 'ExpiredToken|InvalidClientTokenId' <<<"${err}"; then
            die "${EXIT_AUTH_ERROR}" \
                "aws login --remote による認証が完了していない、または認証期限が切れています。aws login --remote を実行してから再度実行してください。"
        fi
        if grep -qiE '403|AccessDenied|Forbidden' <<<"${err}"; then
            log_warn "現在の操作権限では S3 オブジェクト s3://${BUCKET}/${STATE_KEY} へアクセスできません。"
            return 1
        fi
        die "${EXIT_GENERIC_ERROR}" "S3 アクセス確認で想定外のエラーが発生しました: ${err}"
    fi
    log_info "S3 アクセス権限確認 OK"
    return 0
}

#--- スイッチバック実行関数 ----------------------------------------------------
# 指定された専用シェルを source で読み込み、AWS 操作権限へスイッチバックする。
run_switchback() {
    require_param "${SWITCHBACK_SHELL_PATH}" "--switchback-shell-path" \
        "自動スイッチバック (--auto-switchback) にはスイッチバック用シェルのパス指定が必要です"

    if [[ ! -f "${SWITCHBACK_SHELL_PATH}" ]]; then
        die "${EXIT_SWITCHBACK_ERROR}" \
            "スイッチバック用シェルが存在しません: ${SWITCHBACK_SHELL_PATH}"
    fi
    if [[ ! -r "${SWITCHBACK_SHELL_PATH}" ]]; then
        die "${EXIT_SWITCHBACK_ERROR}" \
            "スイッチバック用シェルに読み取り権限がありません: ${SWITCHBACK_SHELL_PATH}"
    fi

    log_info "スイッチバック用シェルを読み込みます: ${SWITCHBACK_SHELL_PATH}"

    # 外部シェルが set -eu 前提で書かれていない可能性があるため、一時的に緩和する
    local old_opts="$-"
    set +e
    set +u
    # shellcheck disable=SC1090
    source "${SWITCHBACK_SHELL_PATH}"
    local rc=$?
    [[ "${old_opts}" == *e* ]] && set -e
    [[ "${old_opts}" == *u* ]] && set -u

    if [[ ${rc} -ne 0 ]]; then
        die "${EXIT_SWITCHBACK_ERROR}" \
            "スイッチバック用シェルの実行に失敗しました (exit=${rc}): ${SWITCHBACK_SHELL_PATH}。シェルの内容と実行環境を確認してください。"
    fi

    SWITCHBACK_EXECUTED="true"
    log_info "スイッチバックが完了しました。認証・権限を再確認します。"

    # スイッチバック後の再確認
    check_aws_auth
    if ! check_aws_permission; then
        die "${EXIT_SWITCHBACK_ERROR}" \
            "スイッチバック後も必要な AWS 操作権限が確認できませんでした。スイッチバック用シェルの内容、および割り当てられる権限を確認してください。"
    fi
}

#--- Terraform実行関数 ---------------------------------------------------------
# usage: run_terraform <サブコマンド...>
# WORKDIR 内で terraform を実行する。失敗時は原因を切り分けて die する。
run_terraform() {
    local logfile="${WORKDIR}/terraform_cmd.log"
    log_debug "terraform 実行: terraform -chdir=${WORKDIR} $*"

    local rc=0
    if [[ "${DEBUG}" == "true" ]]; then
        terraform -chdir="${WORKDIR}" "$@" 2>&1 | tee "${logfile}" >&2 || rc=$?
    else
        terraform -chdir="${WORKDIR}" "$@" >"${logfile}" 2>&1 || rc=$?
    fi

    if [[ ${rc} -ne 0 ]]; then
        log_error "terraform $1 が失敗しました (exit=${rc})。"
        # 失敗原因の切り分け
        if grep -qiE 'AccessDenied|Access Denied|403' "${logfile}"; then
            log_error "原因: S3 もしくは assume role の権限不足の可能性があります。"
        elif grep -qiE 'ExpiredToken|InvalidClientTokenId|no valid credential' "${logfile}"; then
            log_error "原因: AWS 認証情報が無効または期限切れの可能性があります。aws login --remote を再実行してください。"
        elif grep -qiE 'NoSuchBucket' "${logfile}"; then
            log_error "原因: S3 バケットが存在しません。--bucket の指定を確認してください。"
        elif grep -qiE 'NoSuchKey|Unable to find remote state' "${logfile}"; then
            log_error "原因: 指定した state key が存在しません。--state-key の指定を確認してください。"
        elif grep -qiE 'Unsupported argument|Invalid block|Argument or block definition required|Invalid expression' "${logfile}"; then
            log_error "原因: 生成された、または指定された Terraform コードの構文・引数に問題があります。--debug で生成コードを確認してください。"
        fi
        log_error "----- terraform 出力 (末尾20行) -----"
        tail -n 20 "${logfile}" >&2
        log_error "-------------------------------------"
        exit "${EXIT_TERRAFORM_ERROR}"
    fi
}

#--- クリーンアップ関数 --------------------------------------------------------
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        if [[ "${KEEP_WORKDIR}" == "true" ]]; then
            log_info "作業ディレクトリを保持します (--keep-workdir): ${WORKDIR}"
        else
            rm -rf -- "${WORKDIR}" 2>/dev/null || \
                log_warn "作業ディレクトリの削除に失敗しました: ${WORKDIR}"
            log_debug "作業ディレクトリを削除しました: ${WORKDIR}"
        fi
    fi
    exit "${rc}"
}

#===============================================================================
# ヘルプ
#===============================================================================
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

概要:
  S3 バックエンドの Terraform リモートステートを terraform_remote_state
  データソースで実際に読み取り、定義の動作確認と output 値の取得を行います。

使用方法:
  ${SCRIPT_NAME} [オプション]

動作モード:
  A) データソースコード検証モード:
     --terraform-data-source-file で既存の .tf 定義を渡して動作確認します。
  B) パラメータ生成モード:
     --bucket / --state-key / --region から定義を自動生成します。
  いずれのモードでも、以下を組み合わせられます:
     --output-key : 指定キーの値を直接取得
     --search     : キー候補を検索し、番号選択して値を取得
     (どちらも未指定の場合は、取得可能な output キー一覧を表示)

必須パラメータ (モードB の場合):
  --bucket <name>            リモートステートの S3 バケット名
  --state-key <key>          リモートステートファイルのキー (例: network/terraform.tfstate)
  --region <region>          AWS リージョン (例: ap-northeast-1)

任意パラメータ:
  --terraform-data-source-file <path>
                             terraform_remote_state データソース定義 (.tf) ファイル
  --data-source-name <name>  データソース名 (既定: remote_state)
  --output-key <key>         取得対象の output キー
  --search <string>          output キーの検索文字列 (部分一致・大文字小文字無視)
  --role-arn <arn>           assume role に利用する Role ARN
  --external-id <id>         assume role に必要な External ID
  --profile <name>           AWS プロファイル名
  --switchback-shell-path <path>
                             スイッチバック用シェルのパス (source で読み込み)
  --auto-switchback          権限不足時に自動スイッチバックして継続する
  --no-auto-switchback       権限不足時は警告して終了する (既定)
  --common-sh-path <path>    外部 common.sh のパス (省略時は内蔵の共通関数で動作)
  --debug                    生成コード・実行コマンド・terraform 出力を表示する
  --keep-workdir             終了時に一時作業ディレクトリを削除しない
  --help                     このヘルプを表示する

実行例:
  # 1) 既存の .tf 定義ファイルの動作確認 (キー一覧を表示)
  ${SCRIPT_NAME} --terraform-data-source-file ./remote_state.tf

  # 2) パラメータ指定で特定の output キーを直接取得
  ${SCRIPT_NAME} --bucket team-a-tfstate --state-key network/terraform.tfstate \\
      --region ap-northeast-1 --output-key vpc_id

  # 3) 検索文字列でキー候補を表示し、番号選択して値を取得
  ${SCRIPT_NAME} --bucket team-a-tfstate --state-key network/terraform.tfstate \\
      --region ap-northeast-1 --search subnet

  # 4) assume role + 自動スイッチバックを併用
  ${SCRIPT_NAME} --bucket team-a-tfstate --state-key network/terraform.tfstate \\
      --region ap-northeast-1 --role-arn arn:aws:iam::123456789012:role/tfstate-read \\
      --external-id my-external-id \\
      --auto-switchback --switchback-shell-path /opt/tools/switchback_aws.sh

終了コード:
  0: 正常終了  2: パラメータ不正  3: AWS認証エラー  4: 権限不足
  5: スイッチバック失敗  6: Terraform実行失敗  1: その他のエラー
EOF
}

#===============================================================================
# 引数解析
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bucket)                      BUCKET="${2:?--bucket に値が必要です}"; shift 2 ;;
            --state-key)                   STATE_KEY="${2:?--state-key に値が必要です}"; shift 2 ;;
            --region)                      REGION="${2:?--region に値が必要です}"; shift 2 ;;
            --data-source-name)            DATA_SOURCE_NAME="${2:?--data-source-name に値が必要です}"; shift 2 ;;
            --output-key)                  OUTPUT_KEY="${2:?--output-key に値が必要です}"; shift 2 ;;
            --search)                      SEARCH_STRING="${2:?--search に値が必要です}"; shift 2 ;;
            --role-arn)                    ROLE_ARN="${2:?--role-arn に値が必要です}"; shift 2 ;;
            --external-id)                 EXTERNAL_ID="${2:?--external-id に値が必要です}"; shift 2 ;;
            --profile)                     AWS_PROFILE_NAME="${2:?--profile に値が必要です}"; shift 2 ;;
            --terraform-data-source-file)  TF_DATA_SOURCE_FILE="${2:?--terraform-data-source-file に値が必要です}"; shift 2 ;;
            --switchback-shell-path)       SWITCHBACK_SHELL_PATH="${2:?--switchback-shell-path に値が必要です}"; shift 2 ;;
            --auto-switchback)             AUTO_SWITCHBACK="true"; shift ;;
            --no-auto-switchback)          AUTO_SWITCHBACK="false"; shift ;;
            --common-sh-path)              COMMON_SH_PATH="${2:?--common-sh-path に値が必要です}"; shift 2 ;;
            --debug)                       DEBUG="true"; shift ;;
            --keep-workdir)                KEEP_WORKDIR="true"; shift ;;
            --help|-h)                     usage; exit "${EXIT_OK}" ;;
            *)
                die "${EXIT_PARAM_ERROR}" "不明なオプションです: '$1'。--help で使用方法を確認してください。"
                ;;
        esac
    done
}

#--- パラメータ整合性チェック --------------------------------------------------
validate_args() {
    if [[ -n "${TF_DATA_SOURCE_FILE}" ]]; then
        # モードA: .tf ファイル指定
        if [[ ! -f "${TF_DATA_SOURCE_FILE}" ]]; then
            die "${EXIT_PARAM_ERROR}" \
                "--terraform-data-source-file で指定されたファイルが存在しません: ${TF_DATA_SOURCE_FILE}"
        fi
        if [[ ! -r "${TF_DATA_SOURCE_FILE}" ]]; then
            die "${EXIT_PARAM_ERROR}" \
                "--terraform-data-source-file で指定されたファイルに読み取り権限がありません: ${TF_DATA_SOURCE_FILE}"
        fi
    else
        # モードB: パラメータから生成
        local missing=()
        [[ -z "${BUCKET}"    ]] && missing+=("--bucket (S3バケット名)")
        [[ -z "${STATE_KEY}" ]] && missing+=("--state-key (リモートステートファイルのキー)")
        [[ -z "${REGION}"    ]] && missing+=("--region (AWSリージョン)")
        if [[ ${#missing[@]} -gt 0 ]]; then
            die "${EXIT_PARAM_ERROR}" \
                "必須パラメータが不足しています: ${missing[*]}。--terraform-data-source-file を使用しない場合、これらは必須です。--help を参照してください。"
        fi
    fi

    if [[ -n "${OUTPUT_KEY}" && -n "${SEARCH_STRING}" ]]; then
        die "${EXIT_PARAM_ERROR}" \
            "--output-key と --search は同時に指定できません。値を直接取得する場合は --output-key、候補から選択する場合は --search を指定してください。"
    fi

    if [[ -n "${EXTERNAL_ID}" && -z "${ROLE_ARN}" ]]; then
        die "${EXIT_PARAM_ERROR}" \
            "--external-id が指定されていますが --role-arn がありません。External ID は assume role と併用してください。"
    fi

    if [[ "${AUTO_SWITCHBACK}" == "true" && -z "${SWITCHBACK_SHELL_PATH}" ]]; then
        die "${EXIT_PARAM_ERROR}" \
            "--auto-switchback を指定する場合は --switchback-shell-path でスイッチバック用シェルのパスを指定してください。"
    fi
}

#===============================================================================
# Terraform コード生成
#===============================================================================

#--- Terraform バージョン取得 --------------------------------------------------
detect_terraform_version() {
    TF_VERSION="$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || true)"
    if [[ -z "${TF_VERSION}" || "${TF_VERSION}" == "null" ]]; then
        # 旧形式のフォールバック
        TF_VERSION="$(terraform version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
    fi
    log_info "Terraform バージョン: ${TF_VERSION:-unknown}"
}

#--- バージョン比較 (v1 >= v2 なら 0) -------------------------------------------
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

#--- .tf ファイルからデータソース名を抽出 ---------------------------------------
extract_data_source_name() {
    local names
    names="$(grep -oE 'data[[:space:]]+"terraform_remote_state"[[:space:]]+"[A-Za-z0-9_-]+"' \
                 "${TF_DATA_SOURCE_FILE}" \
             | sed -E 's/.*"terraform_remote_state"[[:space:]]+"([A-Za-z0-9_-]+)".*/\1/' || true)"

    local count
    count="$(printf '%s' "${names}" | grep -c . || true)"
    if [[ "${count}" -eq 0 ]]; then
        die "${EXIT_PARAM_ERROR}" \
            "指定ファイルに data \"terraform_remote_state\" ブロックが見つかりません: ${TF_DATA_SOURCE_FILE}"
    fi
    if [[ "${count}" -gt 1 ]]; then
        die "${EXIT_PARAM_ERROR}" \
            "指定ファイルに terraform_remote_state データソースが複数定義されています (${count}件)。1ファイル1定義にしてください: ${TF_DATA_SOURCE_FILE}"
    fi
    DATA_SOURCE_NAME="${names}"
    log_info "データソース名を検出しました: ${DATA_SOURCE_NAME}"
}

#--- main.tf 生成 ---------------------------------------------------------------
generate_main_tf() {
    local main_tf="${WORKDIR}/main.tf"

    if [[ -n "${TF_DATA_SOURCE_FILE}" ]]; then
        # モードA: 指定された定義をそのまま利用する
        cp -- "${TF_DATA_SOURCE_FILE}" "${main_tf}"
        log_info "指定された Terraform データソース定義を使用します: ${TF_DATA_SOURCE_FILE}"
    else
        # モードB: パラメータから可読性の高い main.tf を生成する
        local extra_config=""
        if [[ -n "${AWS_PROFILE_NAME}" ]]; then
            extra_config+="
    profile = \"${AWS_PROFILE_NAME}\""
        fi
        if [[ -n "${ROLE_ARN}" ]]; then
            if version_ge "${TF_VERSION:-0.0.0}" "1.6.0"; then
                # Terraform 1.6+ では assume_role ブロック形式が推奨
                extra_config+="
    assume_role = {
      role_arn    = \"${ROLE_ARN}\""
                if [[ -n "${EXTERNAL_ID}" ]]; then
                    extra_config+="
      external_id = \"${EXTERNAL_ID}\""
                fi
                extra_config+="
    }"
            else
                # Terraform 1.5 以前はトップレベル指定
                extra_config+="
    role_arn = \"${ROLE_ARN}\""
                if [[ -n "${EXTERNAL_ID}" ]]; then
                    extra_config+="
    external_id = \"${EXTERNAL_ID}\""
                fi
            fi
        fi

        cat >"${main_tf}" <<EOF
#-------------------------------------------------------------
# ${SCRIPT_NAME} により自動生成 ($(date '+%Y-%m-%d %H:%M:%S'))
# 他チーム管理のリモートステート読み取り検証用の定義
#-------------------------------------------------------------
data "terraform_remote_state" "${DATA_SOURCE_NAME}" {
  backend = "s3"

  config = {
    bucket = "${BUCKET}"
    key    = "${STATE_KEY}"
    region = "${REGION}"${extra_config}
  }
}
EOF
        log_info "main.tf を生成しました: ${main_tf}"
    fi

    if [[ "${DEBUG}" == "true" ]]; then
        log_debug "----- 生成/使用する main.tf -----"
        cat "${main_tf}" >&2
        log_debug "---------------------------------"
    fi
}

#--- outputs.tf 生成 ------------------------------------------------------------
# mode=keys : キー一覧のみを output (値を state/ログに出さないため keys() を使用)
# mode=value: キー一覧 + 選択キーの値を output
generate_outputs_tf() {
    local mode="$1"
    local outputs_tf="${WORKDIR}/outputs.tf"

    cat >"${outputs_tf}" <<EOF
#-------------------------------------------------------------
# ${SCRIPT_NAME} により自動生成
#-------------------------------------------------------------
# リモートステートから取得可能な output キーの一覧
output "remote_state_output_keys" {
  description = "リモートステートに定義されている output キー一覧"
  value       = keys(data.terraform_remote_state.${DATA_SOURCE_NAME}.outputs)
}
EOF

    if [[ "${mode}" == "value" ]]; then
        cat >>"${outputs_tf}" <<EOF

# 指定された output キーの値
output "selected_output_value" {
  description = "リモートステートの output '${OUTPUT_KEY}' の値"
  value       = data.terraform_remote_state.${DATA_SOURCE_NAME}.outputs["${OUTPUT_KEY}"]
}
EOF
    fi

    if [[ "${DEBUG}" == "true" ]]; then
        log_debug "----- 生成した outputs.tf -----"
        cat "${outputs_tf}" >&2
        log_debug "-------------------------------"
    fi
}

#===============================================================================
# リモートステート操作
#===============================================================================

#--- init + apply でリモートステートを実読み取りする ----------------------------
terraform_init_and_read() {
    log_info "terraform init を実行しています ..."
    run_terraform init -no-color

    log_info "terraform apply でリモートステートを読み取っています ..."
    run_terraform apply -auto-approve -no-color
}

#--- output キー一覧を取得する (JSON配列で返す) ---------------------------------
get_output_keys_json() {
    local json
    if ! json="$(terraform -chdir="${WORKDIR}" output -json remote_state_output_keys 2>"${WORKDIR}/output_err.log")"; then
        log_error "terraform output の取得に失敗しました。"
        tail -n 10 "${WORKDIR}/output_err.log" >&2
        exit "${EXIT_TERRAFORM_ERROR}"
    fi
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${json}"; then
        die "${EXIT_GENERIC_ERROR}" "output キー一覧の JSON 解析に失敗しました (jq)。--debug で詳細を確認してください。"
    fi
    printf '%s' "${json}"
}

#--- 選択キーの値を取得して表示する ---------------------------------------------
fetch_and_show_value() {
    generate_outputs_tf "value"

    log_info "output キー '${OUTPUT_KEY}' の値を取得しています ..."
    run_terraform apply -auto-approve -no-color

    local value_json
    if ! value_json="$(terraform -chdir="${WORKDIR}" output -json selected_output_value 2>"${WORKDIR}/output_err.log")"; then
        log_error "選択キーの値取得 (terraform output) に失敗しました。"
        tail -n 10 "${WORKDIR}/output_err.log" >&2
        exit "${EXIT_TERRAFORM_ERROR}"
    fi

    echo ""
    echo "=================================================================="
    echo " リモートステート output 取得結果"
    echo "=================================================================="
    echo "  データソース : data.terraform_remote_state.${DATA_SOURCE_NAME}"
    echo "  output キー  : ${OUTPUT_KEY}"
    echo "  取得値 (JSON):"
    jq . <<<"${value_json}" | sed 's/^/    /'
    echo "=================================================================="
}

#--- 検索・番号選択 --------------------------------------------------------------
select_key_interactive() {
    local keys_json="$1"
    local candidates_json

    # 大文字小文字を無視した部分一致でフィルタ
    candidates_json="$(jq --arg s "${SEARCH_STRING}" \
        '[.[] | select(ascii_downcase | contains($s | ascii_downcase))]' <<<"${keys_json}")"

    local count
    count="$(jq 'length' <<<"${candidates_json}")"

    if [[ "${count}" -eq 0 ]]; then
        log_warn "検索文字列 '${SEARCH_STRING}' に一致する output キーは見つかりませんでした。"
        echo ""
        echo "取得可能な output キー一覧:"
        jq -r '.[] | "  - " + .' <<<"${keys_json}"
        exit "${EXIT_GENERIC_ERROR}"
    fi

    echo ""
    echo "検索文字列 '${SEARCH_STRING}' に一致する output キー候補 (${count}件):"
    echo "------------------------------------------------------------------"
    local i=1
    while IFS= read -r key; do
        printf '  [%d] %s\n' "${i}" "${key}"
        i=$((i + 1))
    done < <(jq -r '.[]' <<<"${candidates_json}")
    echo "------------------------------------------------------------------"

    if [[ ! -t 0 && ! -r /dev/tty ]]; then
        die "${EXIT_GENERIC_ERROR}" \
            "対話端末が利用できないため番号選択ができません。--output-key で取得対象キーを直接指定してください。"
    fi

    local choice=""
    while :; do
        printf '値を取得するキーの番号を入力してください (1-%d, q=中止): ' "${count}"
        if [[ -t 0 ]]; then
            read -r choice
        else
            read -r choice </dev/tty
        fi
        if [[ "${choice}" == "q" || "${choice}" == "Q" ]]; then
            log_info "ユーザー操作により中止しました。"
            exit "${EXIT_OK}"
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            break
        fi
        echo "  不正な入力です。1 から ${count} の番号、または q を入力してください。"
    done

    OUTPUT_KEY="$(jq -r --argjson i "$((choice - 1))" '.[$i]' <<<"${candidates_json}")"
    log_info "選択されたキー: ${OUTPUT_KEY}"
}

#===============================================================================
# メイン処理
#===============================================================================
main() {
    parse_args "$@"

    # 外部 common.sh の読み込み (指定時のみ。内蔵関数を上書き可能)
    if [[ -n "${COMMON_SH_PATH}" ]]; then
        if [[ -f "${COMMON_SH_PATH}" && -r "${COMMON_SH_PATH}" ]]; then
            log_info "外部 common.sh を読み込みます: ${COMMON_SH_PATH}"
            # shellcheck disable=SC1090
            source "${COMMON_SH_PATH}"
        else
            log_warn "指定された common.sh が読み込めないため、内蔵の共通関数で動作します: ${COMMON_SH_PATH}"
        fi
    fi

    validate_args

    # 必要コマンドの存在確認
    check_command aws
    check_command terraform
    check_command jq
    check_command mktemp

    detect_terraform_version

    # AWS 認証確認 (aws login --remote 実施済みかを実 API で確認)
    check_aws_auth

    # AWS 操作権限確認 + スイッチバック制御
    # モードA (.tf ファイル指定) で bucket/key が不明な場合、S3 個別チェックは
    # スキップし、Terraform 実行時のエラー切り分けに委ねる。
    if [[ -n "${BUCKET}" && -n "${STATE_KEY}" && -n "${REGION}" ]] || [[ -n "${ROLE_ARN}" ]]; then
        if ! check_aws_permission; then
            if [[ "${AUTO_SWITCHBACK}" == "true" ]]; then
                log_warn "権限不足を検知しました。自動スイッチバックを実行します。"
                run_switchback
            else
                die "${EXIT_PERM_ERROR}" \
                    "現在の操作権限では必要な AWS 操作 (S3/STS) を実行できません。スイッチバックを実施してから再実行するか、--auto-switchback と --switchback-shell-path を指定してください。"
            fi
        fi
    else
        log_info "bucket/state-key/region が未指定のため、S3 事前権限チェックはスキップします (Terraform 実行時に検証されます)。"
    fi

    # 一時作業ディレクトリの作成とクリーンアップ登録
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tfrs_check.XXXXXXXX")"
    trap cleanup EXIT INT TERM
    log_info "一時作業ディレクトリ: ${WORKDIR}"

    # Terraform コード生成
    if [[ -n "${TF_DATA_SOURCE_FILE}" ]]; then
        extract_data_source_name
    fi
    generate_main_tf
    generate_outputs_tf "keys"

    # リモートステートの実読み取り (init + apply)
    terraform_init_and_read
    log_info "terraform_remote_state データソースの読み取りに成功しました。"

    # output キー一覧の取得
    local keys_json key_count
    keys_json="$(get_output_keys_json)"
    key_count="$(jq 'length' <<<"${keys_json}")"

    if [[ "${key_count}" -eq 0 ]]; then
        log_warn "リモートステートに output が1件も定義されていません。データソース自体の読み取りは成功しています。"
        exit "${EXIT_OK}"
    fi

    # モード分岐
    if [[ -n "${SEARCH_STRING}" ]]; then
        # 検索・選択モード
        select_key_interactive "${keys_json}"
        fetch_and_show_value
    elif [[ -n "${OUTPUT_KEY}" ]]; then
        # 直接指定モード: キーの存在を確認してから取得
        if ! jq -e --arg k "${OUTPUT_KEY}" 'index($k) != null' >/dev/null <<<"${keys_json}"; then
            log_error "指定された output キー '${OUTPUT_KEY}' はリモートステートに存在しません。"
            echo "" >&2
            echo "取得可能な output キー一覧:" >&2
            jq -r '.[] | "  - " + .' <<<"${keys_json}" >&2
            exit "${EXIT_GENERIC_ERROR}"
        fi
        fetch_and_show_value
    else
        # 検証のみモード: キー一覧を表示
        echo ""
        echo "=================================================================="
        echo " terraform_remote_state データソース検証結果: 成功"
        echo "=================================================================="
        echo "  データソース : data.terraform_remote_state.${DATA_SOURCE_NAME}"
        echo "  取得可能な output キー (${key_count}件):"
        jq -r '.[] | "    - " + .' <<<"${keys_json}"
        echo "=================================================================="
        echo "  値を取得するには --output-key <キー名> または --search <文字列> を指定してください。"
    fi

    log_info "処理が正常に完了しました。"
    exit "${EXIT_OK}"
}

main "$@"
