#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 在 Objective-C 的 @try/@catch 里执行 block。
///
/// 为什么需要这个 shim：Swift 只能 catch `Error`，**没有任何语法能 catch ObjC 的
/// NSException**。而 AppKit 的约束解算（`-[NSView updateConstraints]`）抛的恰恰是
/// NSException —— 一旦它逃到 `CA::Transaction::commit()`，AppKit 会走进
/// `+[NSApplication _crashOnException:]` 并主动 SIGTRAP，整个进程直接没了
/// （PinShot 2026-10-14 / 2026-10-20 两份崩溃日志就是这个栈）。
///
/// 用法：把「可能抛异常的那一小段布局/内存管理代码」包进来，异常就地吞掉，
/// 进程活着，事后重建 UI 即可。
///
/// @param block 要保护的代码
/// @return nil 表示正常执行完；非 nil 是捕获到的异常描述（name + reason）。
NSString * _Nullable PSRunCatchingException(NS_NOESCAPE void (^block)(void)) NS_SWIFT_NAME(ps_runCatchingException(_:));

NS_ASSUME_NONNULL_END
