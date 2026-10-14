#pragma once
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

namespace settingsAppearance {
inline NSString *const title = @"XYHelper Remote RDP";

inline UIImage *icon() {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(29, 29) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithRed:0 green:0.478 blue:1 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:6] fill];
        [UIColor.whiteColor setStroke];
        [UIColor.whiteColor setFill];
        UIBezierPath *screen = [UIBezierPath bezierPathWithRoundedRect:
            CGRectMake(5, 6, 19, 12) cornerRadius:1.5];
        screen.lineWidth = 1.6;
        [screen stroke];
        UIBezierPath *stand = [UIBezierPath bezierPath];
        [stand moveToPoint:CGPointMake(14.5, 18)];
        [stand addLineToPoint:CGPointMake(14.5, 23)];
        [stand moveToPoint:CGPointMake(10, 23)];
        [stand addLineToPoint:CGPointMake(19, 23)];
        stand.lineWidth = 1.6;
        stand.lineCapStyle = kCGLineCapRound;
        [stand stroke];
        UIBezierPath *pointer = [UIBezierPath bezierPath];
        [pointer moveToPoint:CGPointMake(12, 9)];
        [pointer addLineToPoint:CGPointMake(12, 16)];
        [pointer addLineToPoint:CGPointMake(14, 14.5)];
        [pointer addLineToPoint:CGPointMake(15.5, 17)];
        [pointer addLineToPoint:CGPointMake(17, 16)];
        [pointer addLineToPoint:CGPointMake(15.5, 13.5)];
        [pointer addLineToPoint:CGPointMake(18, 13.5)];
        [pointer closePath];
        [pointer fill];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

inline PSSpecifier *entry(PSListController *target, Class detail) {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:title target:target
        set:NULL get:NULL detail:detail cell:PSLinkCell edit:nil];
    [item setProperty:@"com.xyhelper.remoteipad.general" forKey:@"id"];
    UIImage *image = icon();
    if (image) [item setProperty:image forKey:PSIconImageKey];
    else NSLog(@"XYHelper Remote RDP: Settings icon rendering failed");
    return item;
}
}
