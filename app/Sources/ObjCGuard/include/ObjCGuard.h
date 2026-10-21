#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and catches any Objective-C exception it raises. Swift cannot catch those, and
/// AVAudioEngine / AVAudioPlayerNode raise them when the output device drops ("player did not
/// see an IO cycle") — uncaught, that aborts Navi. Returns nil on success, else the reason.
FOUNDATION_EXPORT NSString * _Nullable NaviCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
