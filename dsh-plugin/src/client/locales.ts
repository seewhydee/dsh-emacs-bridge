// dsh-emacs-bridge — `dsh-emacs-bridge` locale dictionaries. The Simplified
// Chinese dictionary is the key-set source of truth; English is checked
// complete against it (bilingual balance is enforced at registration).
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

/** Simplified Chinese dictionary (the key-set source of truth). */
export const zh = {
  'sendToEmacs': '发送到 Emacs',
  'sentToEmacs': '已发送到 Emacs',
  // The bundle-page Emacs install card (plugins.bundle.config).
  'emacsInstallSummary': 'Emacs 包的安装与更新',
  'emacsPackageTitle': 'Emacs 包',
  'emacsInstallDescription': '通过 package.el 把插件内置的 dsh-bridge.el 安装进 Emacs。',
  'emacsBundledVersionLabel': '内置版本',
  'emacsCommandLabel': 'Emacs 命令',
  'emacsVersionLabel': 'Emacs 版本',
  'emacsStateLabel': '安装状态',
  'emacsStateInstalled': '已安装',
  'emacsStateOutdated': '有更新可用',
  'emacsStateAbsent': '未安装',
  'emacsTargetDirLabel': '安装目标目录',
  'emacsProblemNotFound': '找不到 Emacs 命令。请安装 Emacs 29.1 或更高版本,或在该插件行的配置里修改 Emacs 命令。',
  'emacsProblemVersionUnknown': '无法识别 Emacs 版本:该命令没有返回预期的版本信息。',
  'emacsProblemTooOld': 'Emacs 版本过低(当前 {version},需要 29.1 或更高)。',
  'emacsProblemProbeFailed': 'Emacs 状态探测失败。',
  'emacsStatusLoading': '正在探测 Emacs 状态…',
  'emacsStatusError': '状态查询失败:{message}',
  'emacsInstallButton': '安装 Emacs 包',
  'emacsInstallConfirm': '确认运行:{command} --batch --eval "(progn (require \'package) (package-install-file <内置 dsh-bridge.el>))"?安装目标:{dir}',
  'emacsInstallConfirmButton': '确认安装',
  'emacsInstallCancel': '取消',
  'emacsInstallRunning': '正在安装…',
  'emacsInstallSuccess': '安装完成。重启 Emacs,或在运行中的会话里执行 M-: (package-initialize) 后即可使用。',
  'emacsInstallManualLabel': '也可在运行中的 Emacs 里求值:',
  'emacsInstallFailed': '安装失败。',
  'emacsInstallProblemSpawnFailed': '无法启动 Emacs 命令。',
  'emacsInstallProblemTimedOut': '安装超时。',
  'emacsInstallProblemNonzeroExit': 'Emacs 以退出状态 {status} 结束。',
  // The bridge row's configuration fields (plugins.row.config).
  'configSummary': 'Emacs 命令与安装超时',
  'configUnavailable': '此部署未向网页端提供该配置。',
  'configReadOnly': '该配置在此部署中为只读。',
  'configSave': '保存',
  'configSaving': '正在保存…',
  'configSaveFailed': '保存未被接受。',
  'configInvalidTimeout': '需为正整数(毫秒)。',
  'emacsCommandHint': '安装时运行的 Emacs 命令;可带参数,例如 emacs -l ~/.emacs.d/init.el。留空恢复默认 emacs。',
  'emacsInstallTimeoutLabel': '安装超时(毫秒)',
  'emacsInstallTimeoutHint': '批处理安装的最长运行时间,单位为毫秒。',
} satisfies Record<string, string>

/** The dsh-emacs-bridge namespace key union. */
export type DshBridgeKey = keyof typeof zh

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** The dsh-emacs bridge "Send to Emacs" action copy. */
    'dsh-emacs-bridge': DshBridgeKey
  }
}

/** English dictionary, checked complete against the zh key set. */
export const en = {
  'sendToEmacs': 'Send to Emacs',
  'sentToEmacs': 'Sent to Emacs',
  // The bundle-page Emacs install card (plugins.bundle.config).
  'emacsInstallSummary': 'Emacs package install and update',
  'emacsPackageTitle': 'Emacs package',
  'emacsInstallDescription': 'Installs the bundled dsh-bridge.el into Emacs through package.el.',
  'emacsBundledVersionLabel': 'Bundled version',
  'emacsCommandLabel': 'Emacs command',
  'emacsVersionLabel': 'Emacs version',
  'emacsStateLabel': 'Install state',
  'emacsStateInstalled': 'Installed',
  'emacsStateOutdated': 'Update available',
  'emacsStateAbsent': 'Not installed',
  'emacsTargetDirLabel': 'Install target directory',
  'emacsProblemNotFound': 'The Emacs command was not found. Install Emacs 29.1 or newer, or adjust the Emacs command in this plugin row\'s configuration.',
  'emacsProblemVersionUnknown': 'Could not recognize the Emacs version: the command did not print the expected version line.',
  'emacsProblemTooOld': 'Emacs is too old (found {version}; 29.1 or newer is required).',
  'emacsProblemProbeFailed': 'The Emacs status probe failed.',
  'emacsStatusLoading': 'Probing Emacs status…',
  'emacsStatusError': 'Status query failed: {message}',
  'emacsInstallButton': 'Install Emacs package',
  'emacsInstallConfirm': 'Confirm running: {command} --batch --eval "(progn (require \'package) (package-install-file <bundled dsh-bridge.el>))"? Install target: {dir}',
  'emacsInstallConfirmButton': 'Confirm install',
  'emacsInstallCancel': 'Cancel',
  'emacsInstallRunning': 'Installing…',
  'emacsInstallSuccess': 'Installed. Restart Emacs, or evaluate M-: (package-initialize) in a running session, to start using it.',
  'emacsInstallManualLabel': 'Or evaluate in a running Emacs:',
  'emacsInstallFailed': 'Install failed.',
  'emacsInstallProblemSpawnFailed': 'The Emacs command could not be started.',
  'emacsInstallProblemTimedOut': 'The install timed out.',
  'emacsInstallProblemNonzeroExit': 'Emacs exited with status {status}.',
  // The bridge row's configuration fields (plugins.row.config).
  'configSummary': 'Emacs command and install timeout',
  'configUnavailable': 'This deployment does not serve this configuration to the web UI.',
  'configReadOnly': 'This configuration is read-only in this deployment.',
  'configSave': 'Save',
  'configSaving': 'Saving…',
  'configSaveFailed': 'The save was not accepted.',
  'configInvalidTimeout': 'Must be a positive integer (milliseconds).',
  'emacsCommandHint': 'The Emacs command run for installs; arguments are allowed, e.g. emacs -l ~/.emacs.d/init.el. Leave empty to restore the default (emacs).',
  'emacsInstallTimeoutLabel': 'Install timeout (ms)',
  'emacsInstallTimeoutHint': 'How long the batch install may run, in milliseconds.',
} satisfies Record<DshBridgeKey, string>
