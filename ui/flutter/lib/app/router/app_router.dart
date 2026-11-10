import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/tasks/application/task_list_navigation.dart';

import '../../features/extensions/presentation/pages/extensions_page.dart';
import '../../features/extensions/presentation/pages/extension_details_page.dart';
import '../../features/extensions/application/extensions_controller.dart';
import '../../features/auth/application/web_auth_controller.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../api/model/create_task.dart';
import '../../api/model/downloader_config.dart';
import '../../api/model/options.dart';
import '../../api/model/request.dart';
import '../../core/capabilities/app_capabilities.dart';
import '../../core/platform/system_bridge.dart';
import '../../util/util.dart';
import '../../core/window/app_window_chrome.dart';
import '../../core/window/app_window_launcher.dart';
import '../../core/window/app_window_payload.dart';
import '../../features/tasks/application/pending_create_task.dart';
import 'app_window_content.dart';
import 'app_window_page.dart';
import '../../features/tasks/domain/task_record.dart';
import '../../features/tasks/presentation/pages/task_details_page.dart';
import '../../features/tasks/presentation/pages/task_files_page.dart';
import 'shells/main_shell.dart';
import 'mobile_exit_guard.dart';
import 'runtime_page.dart';
import '../../app/application/app_runtime_controller.dart';
import '../../shared/theme/app_palette.dart';

class AppRouter {
  static final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

  static bool get _isMobile =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> openCreateTask({CreateTask? createTask}) async {
    // 静默下载必须在「打开创建页之前」拦截，否则页面已经出现就晚了。
    if (await _tryCreateSilently(createTask: createTask)) return;
    await openWindow(AppWindowPayload.createTask(createTask: createTask?.toJson()));
  }

  /// 静默下载。返回 true 表示已在本方法内完成创建，调用方不应再打开创建页。
  ///
  /// 每次都从后端读最新配置（不要读 runtime 缓存，否则刚改完开关读到的仍是旧值）。
  static Future<bool> _tryCreateSilently({CreateTask? createTask}) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(gopeedServiceProvider);

    final DownloaderConfig config;
    try {
      config = await service.getConfig();
    } catch (_) {
      return false;
    }
    final extra = config.extra;
    if (!extra.silentEnabled) return false;

    final urls = <String>[];
    final presetsName = createTask?.opts?.name ?? '';
    final presetsPath = createTask?.opts?.path ?? '';
    final direct = createTask?.req?.url?.trim() ?? '';
    if (direct.isNotEmpty) urls.add(direct);
    if (urls.isEmpty) {
      // 点「+」没有带链接时，从剪贴板取。
      try {
        final data = await Clipboard.getData('text/plain');
        urls.addAll(
          Util.textToLines(data?.text ?? '')
              .map((line) => line.trim())
              .where((line) => _looksLikeDownloadLink(line)),
        );
      } catch (_) {
        // 剪贴板可能被系统拒绝，属于正常情况。
      }
    }
    // 没有可用链接就退回正常创建页，让用户自己填。
    if (urls.isEmpty) return false;

    try {
      for (final url in urls) {
        await service.createTask(
          CreateTask(
            req: Request(url: url),
            opts: Options(name: urls.length == 1 ? presetsName : '', path: presetsPath),
          ),
        );
      }
    } catch (_) {
      // 创建失败则交回创建页，让用户看到具体错误。
      return false;
    }

    if (extra.silentHeadless) {
      // 无界面模式：任务已建好，不打开任何页面。
      //
      // 注意：外链下载在原生层就被 SilentGateActivity 接走了（Theme.NoDisplay，
      // 根本不绘制窗口），不会走到这里。这里只对应「用户在 App 内点 + 号」的情况，
      // 用户本来就在看界面，不能把他踢到后台——之前正是那句 moveTaskToBack
      // 造成了「闪一下 + 留个后台界面」的观感。
      return true;
    }
    // 静默模式：直接进入任务列表查看进度。
    container.read(taskListNavigationProvider.notifier).showDownloading();
    GoRouter.of(context).go('/');
    return true;
  }

  static bool _looksLikeDownloadLink(String text) {
    if (text.isEmpty) return false;
    final lower = text.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('magnet:') ||
        lower.startsWith('ed2k:') ||
        lower.startsWith('ftp://') ||
        lower.startsWith('ftps://') ||
        lower.startsWith('ftpes://') ||
        lower.startsWith('thunder://');
  }

  /// Opens a desktop child window, a Web modal, or a native mobile page.
  /// Callers never need to choose a presentation or implement a fallback.
  static Future<void> openWindow(AppWindowPayload payload) async {
    final location = AppWindowContent.location(payload.type);
    if (AppWindowChrome.isDesktopWindow && await AppWindowLauncher.open(payload)) return;
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final router = GoRouter.of(context);
    if (router.state.uri.path == location) {
      // Native share intents may arrive while the creation page is already open.
      if (payload.type == AppWindowType.createTask && payload.createTask != null) {
        ProviderScope.containerOf(
          context,
          listen: false,
        ).read(pendingCreateTaskProvider.notifier).set(CreateTask.fromJson(payload.createTask!));
      }
      return;
    }
    if (_isMobile) {
      router.go(location, extra: payload.toRaw());
    } else {
      unawaited(router.push<void>(location, extra: payload.toRaw()));
    }
  }

  static void showDownloadingTasks() {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ProviderScope.containerOf(context, listen: false).read(taskListNavigationProvider.notifier).showDownloading();
    GoRouter.of(context).go('/');
  }

  static GoRouter build(WebAuthController webAuthController) {
    // Keep desktop and web sections as peers; native mobile retains home below them.
    final isMobile = _isMobile;
    final sectionRoutes = [
      GoRoute(
        path: isMobile ? 'extensions' : '/extensions',
        builder: _runtimePage((context, state) => const ExtensionsPage()),
        routes: [
          GoRoute(
            path: ':id',
            builder: _runtimePage(
              (context, state) => ExtensionDetailsPage(
                extensionId: state.pathParameters['id'] ?? '',
                initialItem: state.extra is ExtensionListItem ? state.extra as ExtensionListItem : null,
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        path: isMobile ? 'settings' : '/settings',
        builder: _runtimePage((context, state) => const SettingsPage()),
        routes: [
          GoRoute(
            path: ':section',
            builder: _runtimePage((context, state) => SettingsPage(sectionKey: state.pathParameters['section'])),
          ),
        ],
      ),
    ];
    return GoRouter(
      navigatorKey: rootNavigatorKey,
      refreshListenable: webAuthController,
      redirect: (context, state) {
        final onLoginPage = state.matchedLocation == '/login';
        if (webAuthController.loginRequired) {
          if (onLoginPage) return null;
          return Uri(path: '/login', queryParameters: {'from': state.uri.toString()}).toString();
        }
        if (onLoginPage) {
          return _safeReturnLocation(state.uri.queryParameters['from']);
        }
        return null;
      },
      routes: [
        GoRoute(path: '/login', parentNavigatorKey: rootNavigatorKey, builder: (context, state) => const LoginPage()),
        ShellRoute(
          builder: (context, state, child) => MobileExitGuard(child: MainShell(child: child)),
          routes: [
            GoRoute(
              path: '/',
              builder: _runtimePage((context, state) => const HomePage()),
              routes: [
                GoRoute(
                  path: 'create',
                  parentNavigatorKey: rootNavigatorKey,
                  pageBuilder: (context, state) {
                    final payload = state.extra is String
                        ? AppWindowPayload.fromRaw(state.extra! as String)
                        : AppWindowPayload.createTask();
                    final child = RuntimePage(
                      builder: (context) => AppWindowContent.build(
                        payload,
                        modal: !isMobile,
                        onClose: (created) {
                          if (created) {
                            showDownloadingTasks();
                          } else if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go('/');
                          }
                        },
                      ),
                    );
                    return isMobile
                        ? CustomTransitionPage<void>(
                            key: state.pageKey,
                            transitionDuration: const Duration(milliseconds: 220),
                            reverseTransitionDuration: const Duration(milliseconds: 160),
                            transitionsBuilder: (context, animation, secondaryAnimation, child) =>
                                FadeTransition(opacity: animation, child: child),
                            child: CreateTaskDialogShell(child: child),
                          )
                        : AppWindowPage<void>(key: state.pageKey, child: child);
                  },
                ),
                GoRoute(
                  path: 'tasks/:id',
                  builder: _runtimePage(
                    (context, state) => TaskDetailsPage(
                      taskId: state.pathParameters['id'] ?? '',
                      initialTask: state.extra is TaskRecord ? state.extra as TaskRecord : null,
                    ),
                  ),
                  routes: [
                    GoRoute(
                      path: 'files',
                      builder: _runtimePage(
                        (context, state) => TaskFilesPage(
                          taskId: state.pathParameters['id'] ?? '',
                          initialTask: state.extra is TaskRecord ? state.extra as TaskRecord : null,
                        ),
                      ),
                    ),
                  ],
                ),
                if (isMobile) ...sectionRoutes,
              ],
            ),
            if (!isMobile) ...sectionRoutes,
          ],
        ),
      ],
    );
  }

  static GoRouterWidgetBuilder _runtimePage(GoRouterWidgetBuilder builder) {
    return (context, state) => RuntimePage(builder: (context) => builder(context, state));
  }

  static String _safeReturnLocation(String? location) {
    if (location == null || location.isEmpty) return '/';
    final uri = Uri.tryParse(location);
    if (uri == null || uri.hasScheme || uri.host.isNotEmpty || !location.startsWith('/') || uri.path == '/login') {
      return '/';
    }
    return location;
  }
}

/// 移动端创建任务的弹窗外壳。
///
/// 之前移动端直接是全屏页，所以「居中浮窗 / 底部弹出」这个设置根本不生效。
/// 这里改成真正的悬浮弹窗：半透明遮罩 + 居中或贴底的圆角卡片。
class CreateTaskDialogShell extends ConsumerWidget {
  const CreateTaskDialogShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final extra = ref.watch(appRuntimeControllerProvider).value?.downloaderConfig.extra;
    final fromBottom = extra?.dialogPopsFromBottom ?? false;

    final screen = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = screen.height * (fromBottom ? 0.90 : 0.84);

    final radius = fromBottom
        ? const BorderRadius.vertical(top: Radius.circular(22))
        : const BorderRadius.all(Radius.circular(22));

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (Navigator.of(context).canPop()) Navigator.of(context).pop();
            },
            child: ColoredBox(color: const Color(0xFF000000).withValues(alpha: 0.40)),
          ),
        ),
        AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: keyboard),
          child: Align(
            alignment: fromBottom ? Alignment.bottomCenter : Alignment.center,
            child: Padding(
              padding: fromBottom
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 18),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 620, maxHeight: maxHeight),
                child: ClipRRect(
                  borderRadius: radius,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.sideBg,
                      borderRadius: radius,
                      border: Border.all(color: palette.border, width: 0.8),
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
