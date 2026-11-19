import 'package:flutter/widgets.dart';

/// 应用根 Navigator 的全局入口。
///
/// 通知栏点击这类「App 之外的入口」没有 BuildContext，只能靠它拿 Navigator
/// 推页面；`main.dart` 在启动时把 [MaterialApp.navigatorKey] 挂到这里。
class AppNavigation {
  AppNavigation._();

  static GlobalKey<NavigatorState>? key;

  static NavigatorState? get navigator => key?.currentState;
}
