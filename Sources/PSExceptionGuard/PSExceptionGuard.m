#import "PSExceptionGuard.h"

NSString * _Nullable PSRunCatchingException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    }
    @catch (NSException *exception) {
        NSString *name = exception.name ?: @"NSException";
        NSString *reason = exception.reason ?: @"(no reason)";
        return [NSString stringWithFormat:@"%@: %@", name, reason];
    }
}
