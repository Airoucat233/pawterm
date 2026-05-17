/// UI strings for the Flutter app. Two language packs (en, zh) live in this file
/// because the set is small and editing pair-wise here is faster than juggling
/// .arb files. When adding a new string:
///   1. Add a `final` field to the [Strings] class.
///   2. Set both `stringsEn` and `stringsZh` constants below.
///   3. Reference via `ref.watch(stringsProvider).<field>` or `context.l10n.<field>`.
class Strings {
  // App brand
  final String appTitle;
  final String appTagline;

  // Bottom nav tabs
  final String tabChat;
  final String tabShell;
  final String tabFiles;
  final String tabGit;

  // Top bar
  final String topBarMoreMenu;
  final String topBarOpenDrawer;

  // Sidebar
  final String sidebarProjectsTitle;
  final String sidebarProjectsSubtitle;
  final String sidebarRefresh;
  final String sidebarManageConnections;
  final String sidebarSettings;
  final String sidebarNoProjects;
  final String sidebarLoadFailed;
  final String sidebarNoSessions;
  final String sidebarNewChat;
  final String sidebarGitButton;

  // Chat empty / status
  final String chatEmptyTitle;
  final String chatEmptyPickProject;
  final String chatStartTalking;
  final String chatConnecting;
  final String chatReady;
  final String chatStreaming;
  final String chatError;
  final String chatStop;
  final String chatReconnect;
  final String chatComposerHint;
  final String chatPickModelTooltip;

  // Shell
  final String shellEmptyTitle;
  final String shellEmptyPickProject;
  final String shellReconnect;
  final String shellSearchHint;
  final String shellSearchNoMatch;
  final String shellSearchHitCountTpl; // {n} of {total}
  final String shellSearchCaseSensitive;
  final String shellCwdCopied;
  final String shellCwdCopyTooltip;

  // Files / Git placeholders
  final String filesComingSoon;
  // Files
  final String filesUp;
  final String filesEmpty;
  final String filesLoadFailedTpl; // {err}
  final String filesDownloadStarted;
  final String filesDownloadDoneTpl; // {name}
  final String filesDownloadFailedTpl; // {err}
  final String filesShareSavedFile;
  final String filesConfirmDownloadTpl; // {name} {size}
  final String filesCancel;
  final String filesDownload;
  final String filesDownloading;
  // Permission modes
  final String permModeTitle;
  final String permModeDefaultLabel;
  final String permModeDefaultDesc;
  final String permModeAcceptEditsLabel;
  final String permModeAcceptEditsDesc;
  final String permModePlanLabel;
  final String permModePlanDesc;
  final String permModeBypassLabel;
  final String permModeBypassDesc;
  final String gitComingSoon;
  final String gitStageAll;
  final String gitTitle;

  // Connections screen
  final String connectionsTitle;
  final String connectionsSubtitle;
  final String connectionsAdd;
  final String connectionsEmpty;
  final String connectionsEmptyHint;
  final String connectionsRemove;
  final String connectionsEdit;
  final String connectionsConnect;
  final String connectionsLastConnected;
  final String connectionsNever;
  final String connectionsTesting;
  final String connectionsTestOk;
  final String connectionsTestFail;

  // Add connection sheet
  final String addConnectionTitle;
  final String addConnectionName;
  final String addConnectionNameHint;
  final String addConnectionUrl;
  final String addConnectionUrlHint;
  final String addConnectionEmoji;
  final String addConnectionSave;
  final String addConnectionCancel;

  // Add project sheet
  final String addProjectTitle;
  final String addProjectName;
  final String addProjectNameHint;
  final String addProjectPath;
  final String addProjectPathHint;
  final String addProjectSave;
  final String addProjectCancel;

  // Settings
  final String settingsTitle;
  final String settingsLanguage;
  final String settingsLanguageSystem;
  final String settingsLanguageEnglish;
  final String settingsLanguageChinese;
  final String settingsBack;
  final String settingsAbout;
  final String settingsVersion;
  final String settingsAuthor;
  final String settingsAppearance;
  final String settingsTheme;
  final String settingsThemeSystem;
  final String settingsThemeLight;
  final String settingsThemeDark;
  final String settingsClaudeModel;
  final String settingsTabConnections;
  final String settingsTabSettings;

  // Connections empty state
  final String connectionsEmptyHintLong;
  final String connectionsAddFirst;
  final String connectionsSectionRecent;
  final String connectionsSectionOther;
  final String connectionsSectionAll;
  final String connectionsTagConnected;
  final String connectionsTagLastUsedTpl; // "上次 {ago}"

  // Time-ago helpers
  final String timeJustNow;
  final String timeMinutesAgoTpl; // "{n}m 前"
  final String timeHoursAgoTpl;   // "{n}h 前"
  final String timeDaysAgoTpl;    // "{n} 天前"
  final String timeWeeksAgoTpl;   // "{n} 周前"

  // Add-connection sheet
  final String addConnectionEditTitle;
  final String addConnectionPortNote;
  final String addConnectionDetecting;
  final String addConnectionDetectedTpl; // "已识别{ver}"
  final String addConnectionNameNicknameHint;
  final String addConnectionUrlHintLan;
  final String addConnectionConnectBtn;
  final String addConnectionServerReturnedTpl; // "服务端返回 {code}"
  final String addConnectionUnreachable;

  // Add-project sheet
  final String addProjectEmptyDir;
  final String addProjectGoParent;
  final String addProjectNewFolder;
  final String addProjectAlreadyAdded;
  final String addProjectDirExists;
  final String addProjectCreateFailedTpl; // "新建失败：{err}"
  final String addProjectNoDirSelected;
  final String addProjectAddNamedTpl; // "添加 {name}"
  final String addProjectAddThisDir;
  final String addProjectNameOptional;
  final String addProjectAutoFillHint;
  final String addProjectNewFolderDialogTitle;
  final String addProjectFolderNameHint;
  final String addProjectCreateBtn;

  // Spinner / streaming status line
  final String spinnerRequesting;
  final String spinnerThinking;
  final String spinnerThoughtForTpl; // "已思考 {s}s"
  final String spinnerToolInput;
  final String spinnerStop;
  final List<String> spinnerRespondingVerbs; // pick one randomly

  // Thinking
  final String thinkingCollapsed;
  final String thinkingExpanded;

  // Time labels
  final String timeYesterday;

  // Generic
  final String genericRetry;
  final String genericClose;
  final String genericConfirm;
  final String genericCancel;

  const Strings({
    required this.appTitle,
    required this.appTagline,
    required this.tabChat,
    required this.tabShell,
    required this.tabFiles,
    required this.tabGit,
    required this.topBarMoreMenu,
    required this.topBarOpenDrawer,
    required this.sidebarProjectsTitle,
    required this.sidebarProjectsSubtitle,
    required this.sidebarRefresh,
    required this.sidebarManageConnections,
    required this.sidebarSettings,
    required this.sidebarNoProjects,
    required this.sidebarLoadFailed,
    required this.sidebarNoSessions,
    required this.sidebarNewChat,
    required this.sidebarGitButton,
    required this.chatEmptyTitle,
    required this.chatEmptyPickProject,
    required this.chatStartTalking,
    required this.chatConnecting,
    required this.chatReady,
    required this.chatStreaming,
    required this.chatError,
    required this.chatStop,
    required this.chatReconnect,
    required this.chatComposerHint,
    required this.chatPickModelTooltip,
    required this.shellEmptyTitle,
    required this.shellEmptyPickProject,
    required this.shellReconnect,
    required this.shellSearchHint,
    required this.shellSearchNoMatch,
    required this.shellSearchHitCountTpl,
    required this.shellSearchCaseSensitive,
    required this.shellCwdCopied,
    required this.shellCwdCopyTooltip,
    required this.filesComingSoon,
    required this.filesUp,
    required this.filesEmpty,
    required this.filesLoadFailedTpl,
    required this.filesDownloadStarted,
    required this.filesDownloadDoneTpl,
    required this.filesDownloadFailedTpl,
    required this.filesShareSavedFile,
    required this.filesConfirmDownloadTpl,
    required this.filesCancel,
    required this.filesDownload,
    required this.filesDownloading,
    required this.permModeTitle,
    required this.permModeDefaultLabel,
    required this.permModeDefaultDesc,
    required this.permModeAcceptEditsLabel,
    required this.permModeAcceptEditsDesc,
    required this.permModePlanLabel,
    required this.permModePlanDesc,
    required this.permModeBypassLabel,
    required this.permModeBypassDesc,
    required this.gitComingSoon,
    required this.gitStageAll,
    required this.gitTitle,
    required this.connectionsTitle,
    required this.connectionsSubtitle,
    required this.connectionsAdd,
    required this.connectionsEmpty,
    required this.connectionsEmptyHint,
    required this.connectionsRemove,
    required this.connectionsEdit,
    required this.connectionsConnect,
    required this.connectionsLastConnected,
    required this.connectionsNever,
    required this.connectionsTesting,
    required this.connectionsTestOk,
    required this.connectionsTestFail,
    required this.addConnectionTitle,
    required this.addConnectionName,
    required this.addConnectionNameHint,
    required this.addConnectionUrl,
    required this.addConnectionUrlHint,
    required this.addConnectionEmoji,
    required this.addConnectionSave,
    required this.addConnectionCancel,
    required this.addProjectTitle,
    required this.addProjectName,
    required this.addProjectNameHint,
    required this.addProjectPath,
    required this.addProjectPathHint,
    required this.addProjectSave,
    required this.addProjectCancel,
    required this.settingsTitle,
    required this.settingsLanguage,
    required this.settingsLanguageSystem,
    required this.settingsLanguageEnglish,
    required this.settingsLanguageChinese,
    required this.settingsBack,
    required this.settingsAbout,
    required this.settingsVersion,
    required this.settingsAuthor,
    required this.settingsAppearance,
    required this.settingsTheme,
    required this.settingsThemeSystem,
    required this.settingsThemeLight,
    required this.settingsThemeDark,
    required this.settingsClaudeModel,
    required this.settingsTabConnections,
    required this.settingsTabSettings,
    required this.connectionsEmptyHintLong,
    required this.connectionsAddFirst,
    required this.connectionsSectionRecent,
    required this.connectionsSectionOther,
    required this.connectionsSectionAll,
    required this.connectionsTagConnected,
    required this.connectionsTagLastUsedTpl,
    required this.timeJustNow,
    required this.timeMinutesAgoTpl,
    required this.timeHoursAgoTpl,
    required this.timeDaysAgoTpl,
    required this.timeWeeksAgoTpl,
    required this.addConnectionEditTitle,
    required this.addConnectionPortNote,
    required this.addConnectionDetecting,
    required this.addConnectionDetectedTpl,
    required this.addConnectionNameNicknameHint,
    required this.addConnectionUrlHintLan,
    required this.addConnectionConnectBtn,
    required this.addConnectionServerReturnedTpl,
    required this.addConnectionUnreachable,
    required this.addProjectEmptyDir,
    required this.addProjectGoParent,
    required this.addProjectNewFolder,
    required this.addProjectAlreadyAdded,
    required this.addProjectDirExists,
    required this.addProjectCreateFailedTpl,
    required this.addProjectNoDirSelected,
    required this.addProjectAddNamedTpl,
    required this.addProjectAddThisDir,
    required this.addProjectNameOptional,
    required this.addProjectAutoFillHint,
    required this.addProjectNewFolderDialogTitle,
    required this.addProjectFolderNameHint,
    required this.addProjectCreateBtn,
    required this.spinnerRequesting,
    required this.spinnerThinking,
    required this.spinnerThoughtForTpl,
    required this.spinnerToolInput,
    required this.spinnerStop,
    required this.spinnerRespondingVerbs,
    required this.thinkingCollapsed,
    required this.thinkingExpanded,
    required this.timeYesterday,
    required this.genericRetry,
    required this.genericClose,
    required this.genericConfirm,
    required this.genericCancel,
  });
}

const Strings stringsEn = Strings(
  appTitle: 'Claude Companion',
  appTagline: 'Mobile control for Claude Code',
  tabChat: 'Chat',
  tabShell: 'Shell',
  tabFiles: 'Files',
  tabGit: 'Git',
  topBarMoreMenu: 'More',
  topBarOpenDrawer: 'Projects',
  sidebarProjectsTitle: 'Working directories',
  sidebarProjectsSubtitle: 'Where Claude can run',
  sidebarRefresh: 'Refresh',
  sidebarManageConnections: 'Manage connections',
  sidebarSettings: 'Settings',
  sidebarNoProjects: 'No projects available',
  sidebarLoadFailed: 'Failed to load',
  sidebarNoSessions: 'No session history',
  sidebarNewChat: 'New chat',
  sidebarGitButton: 'Git',
  chatEmptyTitle: 'No active conversation',
  chatEmptyPickProject: 'Open the menu and pick a project, or start a new chat',
  chatStartTalking: 'Start talking',
  chatConnecting: 'Connecting…',
  chatReady: 'ready',
  chatStreaming: 'streaming',
  chatError: 'error',
  chatStop: 'stop',
  chatReconnect: 'reconnect',
  chatComposerHint: 'Ask Claude…',
  chatPickModelTooltip: 'Switch model',
  shellEmptyTitle: 'No active conversation',
  shellEmptyPickProject: 'Open the menu and pick a project',
  shellReconnect: 'Reconnect',
  shellSearchHint: 'Find in terminal',
  shellSearchNoMatch: 'No matches',
  shellSearchHitCountTpl: '{n} of {total}',
  shellSearchCaseSensitive: 'Aa',
  shellCwdCopied: 'Path copied',
  shellCwdCopyTooltip: 'Copy path',
  filesComingSoon: 'Files (coming soon)',
  filesUp: 'Up',
  filesEmpty: 'Empty folder',
  filesLoadFailedTpl: 'Failed to load: {err}',
  filesDownloadStarted: 'Downloading…',
  filesDownloadDoneTpl: 'Saved {name}',
  filesDownloadFailedTpl: 'Download failed: {err}',
  filesShareSavedFile: 'Share / save…',
  filesConfirmDownloadTpl: 'Download {name} ({size})?',
  filesCancel: 'Cancel',
  filesDownload: 'Download',
  filesDownloading: 'Downloading',
  permModeTitle: 'Permission mode',
  permModeDefaultLabel: 'Ask each time',
  permModeDefaultDesc: 'Confirm every tool call',
  permModeAcceptEditsLabel: 'Auto-accept edits',
  permModeAcceptEditsDesc: 'File edits run without prompting',
  permModePlanLabel: 'Plan mode',
  permModePlanDesc: 'Read-only — Claude plans, doesn\'t execute',
  permModeBypassLabel: 'Bypass all',
  permModeBypassDesc: 'No permission checks — full access',
  gitComingSoon: 'Git diff / stage / commit (coming soon)',
  gitStageAll: 'Stage All',
  gitTitle: 'Git',
  connectionsTitle: 'Connections',
  connectionsSubtitle: 'Servers you can connect to',
  connectionsAdd: 'Add connection',
  connectionsEmpty: 'No connections yet',
  connectionsEmptyHint: 'Tap + to add your first server',
  connectionsRemove: 'Remove',
  connectionsEdit: 'Edit',
  connectionsConnect: 'Connect',
  connectionsLastConnected: 'Last used',
  connectionsNever: 'never',
  connectionsTesting: 'Testing…',
  connectionsTestOk: 'Reachable',
  connectionsTestFail: 'Unreachable',
  addConnectionTitle: 'Add connection',
  addConnectionName: 'Name',
  addConnectionNameHint: 'My Mac, Office desktop, …',
  addConnectionUrl: 'Server URL',
  addConnectionUrlHint: 'http://192.168.1.x or domain',
  addConnectionEmoji: 'Emoji',
  addConnectionSave: 'Save',
  addConnectionCancel: 'Cancel',
  addProjectTitle: 'Add project',
  addProjectName: 'Name',
  addProjectNameHint: 'Optional — defaults to directory name',
  addProjectPath: 'Absolute path',
  addProjectPathHint: '/Users/you/code/my-project',
  addProjectSave: 'Save',
  addProjectCancel: 'Cancel',
  settingsTitle: 'Settings',
  settingsLanguage: 'Language',
  settingsLanguageSystem: 'Follow system',
  settingsLanguageEnglish: 'English',
  settingsLanguageChinese: '中文（简体）',
  settingsBack: 'Back',
  settingsAbout: 'About',
  settingsVersion: 'Version',
  settingsAuthor: 'Author',
  settingsAppearance: 'Appearance',
  settingsTheme: 'Theme',
  settingsThemeSystem: 'Follow system',
  settingsThemeLight: 'Light',
  settingsThemeDark: 'Dark',
  settingsClaudeModel: 'Claude model',
  settingsTabConnections: 'Connections',
  settingsTabSettings: 'Settings',
  connectionsEmptyHintLong:
      'Add a machine running Claude Companion Server\nand control it from your phone.',
  connectionsAddFirst: 'Add the first one',
  connectionsSectionRecent: 'Recent',
  connectionsSectionOther: 'Others',
  connectionsSectionAll: 'All',
  connectionsTagConnected: 'Connected',
  connectionsTagLastUsedTpl: 'last {ago}',
  timeJustNow: 'just now',
  timeMinutesAgoTpl: '{n}m ago',
  timeHoursAgoTpl: '{n}h ago',
  timeDaysAgoTpl: '{n}d ago',
  timeWeeksAgoTpl: '{n}w ago',
  addConnectionEditTitle: 'Edit connection',
  addConnectionPortNote: 'Default port 8765; use IP:port to override',
  addConnectionDetecting: 'Connecting and identifying server…',
  addConnectionDetectedTpl: 'Detected{ver}',
  addConnectionNameNicknameHint: 'Editable nickname',
  addConnectionUrlHintLan: '192.168.1.x or domain',
  addConnectionConnectBtn: 'Connect',
  addConnectionServerReturnedTpl: 'Server returned {code}',
  addConnectionUnreachable: 'Cannot connect, check the address and port',
  addProjectEmptyDir: 'Empty directory',
  addProjectGoParent: 'Up',
  addProjectNewFolder: 'New folder',
  addProjectAlreadyAdded: 'This directory is already in the project list',
  addProjectDirExists: 'A directory with that name already exists',
  addProjectCreateFailedTpl: 'Create failed: {err}',
  addProjectNoDirSelected: 'No directory selected',
  addProjectAddNamedTpl: 'Add {name}',
  addProjectAddThisDir: 'Add this directory',
  addProjectNameOptional: '(optional, defaults to folder name)',
  addProjectAutoFillHint: 'Auto-filled after selecting a directory',
  addProjectNewFolderDialogTitle: 'New folder',
  addProjectFolderNameHint: 'Folder name',
  addProjectCreateBtn: 'Create',
  spinnerRequesting: 'Requesting…',
  spinnerThinking: 'Thinking…',
  spinnerThoughtForTpl: 'Thought for {s}s',
  spinnerToolInput: 'Tool args…',
  spinnerStop: 'Stop',
  spinnerRespondingVerbs: [
    'Writing', 'Drafting', 'Composing', 'Crafting', 'Penning',
    'Articulating', 'Formulating', 'Conjuring', 'Sketching', 'Spinning',
    'Shaping', 'Polishing', 'Refining', 'Weaving', 'Brewing',
  ],
  thinkingCollapsed: 'Thinking…',
  thinkingExpanded: 'Thinking trace',
  timeYesterday: 'Yesterday',
  genericRetry: 'Retry',
  genericClose: 'Close',
  genericConfirm: 'OK',
  genericCancel: 'Cancel',
);

const Strings stringsZh = Strings(
  appTitle: 'Claude Companion',
  appTagline: '在手机上操控 Claude Code',
  tabChat: '对话',
  tabShell: '终端',
  tabFiles: '文件',
  tabGit: 'Git',
  topBarMoreMenu: '更多',
  topBarOpenDrawer: '项目',
  sidebarProjectsTitle: '工作目录',
  sidebarProjectsSubtitle: 'Claude 可访问的目录',
  sidebarRefresh: '刷新',
  sidebarManageConnections: '管理连接',
  sidebarSettings: '设置',
  sidebarNoProjects: '没有可用项目',
  sidebarLoadFailed: '加载失败',
  sidebarNoSessions: '暂无历史 session',
  sidebarNewChat: '新对话',
  sidebarGitButton: 'Git',
  chatEmptyTitle: '没有进行中的对话',
  chatEmptyPickProject: '从左上角菜单选择项目，或新建对话',
  chatStartTalking: '开始对话',
  chatConnecting: '正在连接…',
  chatReady: '就绪',
  chatStreaming: '正在回复',
  chatError: '出错',
  chatStop: '中断',
  chatReconnect: '重连',
  chatComposerHint: '向 Claude 提问…',
  chatPickModelTooltip: '切换模型',
  shellEmptyTitle: '没有进行中的对话',
  shellEmptyPickProject: '从左上角菜单选择项目',
  shellReconnect: '重连',
  shellSearchHint: '在终端中查找',
  shellSearchNoMatch: '无匹配',
  shellSearchHitCountTpl: '第 {n} / {total}',
  shellSearchCaseSensitive: 'Aa',
  shellCwdCopied: '路径已复制',
  shellCwdCopyTooltip: '复制路径',
  filesComingSoon: '文件树（即将上线）',
  filesUp: '上级',
  filesEmpty: '空目录',
  filesLoadFailedTpl: '加载失败：{err}',
  filesDownloadStarted: '下载中…',
  filesDownloadDoneTpl: '已下载 {name}',
  filesDownloadFailedTpl: '下载失败：{err}',
  filesShareSavedFile: '分享 / 保存…',
  filesConfirmDownloadTpl: '下载 {name}（{size}）？',
  filesCancel: '取消',
  filesDownload: '下载',
  filesDownloading: '下载中',
  permModeTitle: '权限模式',
  permModeDefaultLabel: '每次询问',
  permModeDefaultDesc: '每次工具调用都确认',
  permModeAcceptEditsLabel: '自动编辑',
  permModeAcceptEditsDesc: '文件编辑免确认',
  permModePlanLabel: '计划模式',
  permModePlanDesc: '只读 — Claude 规划但不执行',
  permModeBypassLabel: '完全放开',
  permModeBypassDesc: '跳过权限检查 — 完全访问',
  gitComingSoon: 'Git 差异 / 暂存 / 提交（即将上线）',
  gitStageAll: '全部暂存',
  gitTitle: 'Git',
  connectionsTitle: '连接管理',
  connectionsSubtitle: '可连接的服务端',
  connectionsAdd: '添加连接',
  connectionsEmpty: '还没有连接',
  connectionsEmptyHint: '点 + 添加你的第一台服务器',
  connectionsRemove: '删除',
  connectionsEdit: '编辑',
  connectionsConnect: '连接',
  connectionsLastConnected: '最近使用',
  connectionsNever: '从未',
  connectionsTesting: '正在测试…',
  connectionsTestOk: '可达',
  connectionsTestFail: '无法连接',
  addConnectionTitle: '添加连接',
  addConnectionName: '名称',
  addConnectionNameHint: '我的 Mac、办公室台式机…',
  addConnectionUrl: '服务端地址',
  addConnectionUrlHint: 'http://192.168.1.x 或 域名',
  addConnectionEmoji: '图标',
  addConnectionSave: '保存',
  addConnectionCancel: '取消',
  addProjectTitle: '添加项目',
  addProjectName: '名称',
  addProjectNameHint: '可选 — 默认用目录名',
  addProjectPath: '绝对路径',
  addProjectPathHint: '/Users/you/code/my-project',
  addProjectSave: '保存',
  addProjectCancel: '取消',
  settingsTitle: '设置',
  settingsLanguage: '语言',
  settingsLanguageSystem: '跟随系统',
  settingsLanguageEnglish: 'English',
  settingsLanguageChinese: '中文（简体）',
  settingsBack: '返回',
  settingsAbout: '关于',
  settingsVersion: '版本',
  settingsAuthor: '作者',
  settingsAppearance: '外观',
  settingsTheme: '主题',
  settingsThemeSystem: '跟随系统',
  settingsThemeLight: '浅色',
  settingsThemeDark: '深色',
  settingsClaudeModel: 'Claude 模型',
  settingsTabConnections: '连接',
  settingsTabSettings: '设置',
  connectionsEmptyHintLong:
      '添加一台运行了 Claude Companion Server\n的机器，就能从手机控制它。',
  connectionsAddFirst: '添加第一台',
  connectionsSectionRecent: '最近使用',
  connectionsSectionOther: '其他',
  connectionsSectionAll: '全部',
  connectionsTagConnected: '已连接',
  connectionsTagLastUsedTpl: '上次 {ago}',
  timeJustNow: '刚刚',
  timeMinutesAgoTpl: '{n}m 前',
  timeHoursAgoTpl: '{n}h 前',
  timeDaysAgoTpl: '{n} 天前',
  timeWeeksAgoTpl: '{n} 周前',
  addConnectionEditTitle: '编辑连接',
  addConnectionPortNote: '端口默认 8765，可写 IP:端口 指定其他端口',
  addConnectionDetecting: '正在连接并识别服务端…',
  addConnectionDetectedTpl: '已识别{ver}',
  addConnectionNameNicknameHint: '可修改昵称',
  addConnectionUrlHintLan: '192.168.1.x 或 域名',
  addConnectionConnectBtn: '连接',
  addConnectionServerReturnedTpl: '服务端返回 {code}',
  addConnectionUnreachable: '无法连接，请检查地址和端口',
  addProjectEmptyDir: '空目录',
  addProjectGoParent: '上级',
  addProjectNewFolder: '新建',
  addProjectAlreadyAdded: '该目录已在项目列表中',
  addProjectDirExists: '同名目录已存在',
  addProjectCreateFailedTpl: '新建失败：{err}',
  addProjectNoDirSelected: '未选择目录',
  addProjectAddNamedTpl: '添加 {name}',
  addProjectAddThisDir: '添加此目录',
  addProjectNameOptional: '（可选，默认为文件夹名）',
  addProjectAutoFillHint: '选择目录后自动填充',
  addProjectNewFolderDialogTitle: '新建文件夹',
  addProjectFolderNameHint: '文件夹名',
  addProjectCreateBtn: '创建',
  spinnerRequesting: '请求中…',
  spinnerThinking: '思考中…',
  spinnerThoughtForTpl: '已思考 {s}s',
  spinnerToolInput: '调用工具…',
  spinnerStop: '停止',
  spinnerRespondingVerbs: [
    '生成中', '推敲中', '酝酿中', '梳理中', '组织中',
    '雕琢中', '构思中', '编织中', '琢磨中', '盘算中',
    '勾画中', '揣摩中', '凝神中', '沉吟中', '运笔中',
  ],
  thinkingCollapsed: '思考片段',
  thinkingExpanded: '思考过程',
  timeYesterday: '昨天',
  genericRetry: '重试',
  genericClose: '关闭',
  genericConfirm: '确定',
  genericCancel: '取消',
);
