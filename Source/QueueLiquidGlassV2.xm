#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static BOOL YTMUQueueV2(void){return YTMULGFeatureEnabled(@"queueV2Enabled");}
static const void*kQueueGlass=&kQueueGlass,&kQueueTint=&kQueueTint,&kQueueSampled=&kQueueSampled;

// One 1x1 downscale of the row's thumbnail -- the same whole-CGImage draw the
// song theme uses. The caller caches the result against the image pointer, so
// this runs once per row per song, never once per layout pass.
static UIColor*YTMUQueueAverage(UIImage*image){
    if(!image.CGImage)return nil;
    unsigned char pixel[4]={0};
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(pixel,1,1,8,4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if(!ctx)return nil;
    CGContextDrawImage(ctx,CGRectMake(0,0,1,1),image.CGImage);
    CGContextRelease(ctx);
    return [UIColor colorWithRed:pixel[0]/255.0 green:pixel[1]/255.0 blue:pixel[2]/255.0 alpha:1.0];
}

// THE ROW'S OWN SONG COLOUR. The panel used to be one flat dark card per row
// with a fixed white 12% edge, so a row whose cover is cyan sat next to one
// whose cover is red with nothing tying either card to its artwork. This pushes
// the thumbnail's average just far enough off grey to read as that song: the
// fill is a 10% wash and the edge is the same hue at 34%. A grey cover has
// saturation 0 and lands on a neutral edge, which is correct -- there is no
// colour to match, and no fallback purple is invented for it.
static UIColor*YTMUQueueHue(UIImage*image){
    UIColor*a=YTMUQueueAverage(image);
    if(!a)return nil;
    CGFloat h=0,s=0,b=0,alpha=0;
    if(![a getHue:&h saturation:&s brightness:&b alpha:&alpha])return nil;
    return [UIColor colorWithHue:h saturation:MIN(.62,MAX(.26,s+.10)) brightness:MIN(.88,MAX(.34,b*1.04)) alpha:1];
}

// 10pt horizontal, symmetric, so the card sits INSIDE the panel on both sides.
// It used to be 4pt, which put the rounded corners within a hair of the panel
// edge and made the card read as part of the panel's own outline.
static void YTMUQueueCard(UIView*h,UIImage*thumb){
    UIVisualEffectView*b=objc_getAssociatedObject(h,kQueueGlass);
    UIView*tint=nil;
    if(!b){
        b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        b.userInteractionEnabled=NO;b.clipsToBounds=YES;b.layer.borderWidth=.6;
        [h insertSubview:b atIndex:0];
        objc_setAssociatedObject(h,kQueueGlass,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The wash rides inside the blur's contentView, so it cannot drift off
        // the card when the cell resizes.
        tint=[[UIView alloc]initWithFrame:CGRectZero];tint.userInteractionEnabled=NO;
        [b.contentView addSubview:tint];
        objc_setAssociatedObject(h,kQueueTint,tint,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }else tint=objc_getAssociatedObject(h,kQueueTint);

    // Only re-sample when this cell is showing a different cover (the queue
    // recycles cells while scrolling, and the same cell is re-laid-out on every
    // queue header update otherwise).
    void*key=(__bridge void*)thumb.CGImage;
    NSValue*last=objc_getAssociatedObject(h,kQueueSampled);
    if(!last||last.pointerValue!=key){
        objc_setAssociatedObject(h,kQueueSampled,[NSValue valueWithPointer:key],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor*hue=YTMUQueueHue(thumb);
        tint.backgroundColor=hue?[hue colorWithAlphaComponent:.10]:[UIColor colorWithWhite:1 alpha:.04];
        b.layer.borderColor=(hue?[hue colorWithAlphaComponent:.34]:[UIColor colorWithWhite:1 alpha:.14]).CGColor;
    }

    CGRect f=CGRectInset(h.bounds,10,3);
    b.frame=f;b.layer.cornerRadius=16;b.layer.cornerCurve=kCACornerCurveContinuous;
    tint.frame=b.bounds;tint.layer.cornerRadius=16;tint.layer.cornerCurve=kCACornerCurveContinuous;
    [h sendSubviewToBack:b];
}

@interface YTMQueueCollectionViewController:UIViewController@end
%hook YTMQueueCollectionViewController
- (void)viewDidLayoutSubviews{
    %orig;if(!YTMUQueueV2())return;
    self.view.backgroundColor=UIColor.clearColor;
    for(UIView*v in self.view.subviews){
        if(![v isKindOfClass:UICollectionView.class])continue;
        v.backgroundColor=UIColor.clearColor;
        // Horizontal content inset on a VERTICALLY scrolling collection view is
        // the bug that put the row cards outside the panel: cells are laid out
        // at the collection view's full width starting at +contentInset.left, so
        // a 12pt left inset shoved every card 12pt right and pushed its right
        // edge 12pt past the panel. A side margin on a list belongs in the
        // layout's sectionInset or in the card itself -- both are below, both
        // symmetric. Top and bottom are kept: they are what lifts the first
        // row off the panel header and the last row off the footer.
        ((UICollectionView*)v).contentInset=UIEdgeInsetsMake(12,0,92,0);
    }
}
%end

@interface YTMPlaylistPanelVideoCell:UICollectionViewCell@end
%hook YTMPlaylistPanelVideoCell
- (void)layoutSubviews{
    %orig;if(!YTMUQueueV2()||CGRectGetWidth(self.bounds)<340||CGRectGetHeight(self.bounds)<60)return;
    self.backgroundColor=UIColor.clearColor;self.contentView.backgroundColor=UIColor.clearColor;
    UIImage*thumb=nil;
    for(UIView*v in self.contentView.subviews){
        if(![NSStringFromClass(v.class)isEqualToString:@"YTImageView"]||CGRectGetWidth(v.bounds)>64)continue;
        v.layer.cornerRadius=10;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;
        if(!thumb)[thumb=((UIImageView*)v).image];
    }
    YTMUQueueCard(self.contentView,thumb);
}
%end
