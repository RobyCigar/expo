// Copyright 2015-present 650 Industries. All rights reserved.

@import UIKit;

#import "EXAnalytics.h"
#import "EXAppLoader.h"
#import "EXAppViewController.h"
#import "EXAppLoadingProgressWindowController.h"
#import "EXAppLoadingCancelView.h"
#import "EXManagedAppSplashScreenViewProvider.h"
#import "EXManagedAppSplashScreenConfigurationBuilder.h"
#import "EXManagedAppSplashScreenViewController.h"
#import "EXHomeAppSplashScreenViewProvider.h"
#import "EXEnvironment.h"
#import "EXErrorRecoveryManager.h"
#import "EXErrorView.h"
#import "EXFileDownloader.h"
#import "EXKernel.h"
#import "EXKernelUtil.h"
#import "EXReactAppManager.h"
#import "EXVersions.h"
#import "EXUpdatesManager.h"
#import "EXUtil.h"

#import <EXSplashScreen/EXSplashScreenService.h>
#import <React/RCTUtils.h>
#import <ExpoModulesCore/EXModuleRegistryProvider.h>

#if __has_include(<EXScreenOrientation/EXScreenOrientationRegistry.h>)
#import <EXScreenOrientation/EXScreenOrientationRegistry.h>
#endif

#import <React/RCTAppearance.h>
#if defined(INCLUDES_VERSIONED_CODE) && __has_include(<ABI43_0_0React/ABI43_0_0RCTAppearance.h>)
#import <ABI43_0_0React/ABI43_0_0RCTAppearance.h>
#endif
#if defined(INCLUDES_VERSIONED_CODE) && __has_include(<ABI42_0_0React/ABI42_0_0RCTAppearance.h>)
#import <ABI42_0_0React/ABI42_0_0RCTAppearance.h>
#endif
#if defined(INCLUDES_VERSIONED_CODE) && __has_include(<ABI41_0_0React/ABI41_0_0RCTAppearance.h>)
#import <ABI41_0_0React/ABI41_0_0RCTAppearance.h>
#endif

#define EX_INTERFACE_ORIENTATION_USE_MANIFEST 0

// when we encounter an error and auto-refresh, we may actually see a series of errors.
// we only want to trigger refresh once, so we debounce refresh on a timer.
const CGFloat kEXAutoReloadDebounceSeconds = 0.1;

// in development only, some errors can happen before we even start loading
// (e.g. certain packager errors, such as an invalid bundle url)
// and we want to make sure not to cover the error with a loading view or other chrome.
const CGFloat kEXDevelopmentErrorCoolDownSeconds = 0.1;

// copy of RNScreens protocol
@protocol EXKernelRNSScreenWindowTraits

+ (BOOL)shouldAskScreensForScreenOrientationInViewController:(UIViewController *)vc;

@end

NS_ASSUME_NONNULL_BEGIN

@interface EXAppViewController ()
  <EXReactAppManagerUIDelegate, EXAppLoaderDelegate, EXErrorViewDelegate, EXAppLoadingCancelViewDelegate>

@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL isBridgeAlreadyLoading;
@property (nonatomic, weak) EXKernelAppRecord *appRecord;
@property (nonatomic, strong) EXErrorView *errorView;
@property (nonatomic, strong) NSTimer *tmrAutoReloadDebounce;
@property (nonatomic, strong) NSDate *dtmLastFatalErrorShown;
@property (nonatomic, strong) NSMutableArray<UIViewController *> *backgroundedControllers;

@property (nonatomic, assign) BOOL isStandalone;
@property (nonatomic, assign) BOOL isHomeApp;

/*
 * Controller for handling all messages from bundler/fetcher.
 * It shows another UIWindow with text and percentage progress.
 * Enabled only in managed workflow or home when in development mode.
 * It should appear once manifest is fetched.
 */
@property (nonatomic, strong, nonnull) EXAppLoadingProgressWindowController *appLoadingProgressWindowController;

/**
 * SplashScreenViewProvider that is used only in managed workflow app.
 * Managed app does not need any specific SplashScreenViewProvider as it uses generic one povided by the SplashScreen module.
 * See also EXHomeAppSplashScreenViewProvider in self.viewDidLoad
 */
@property (nonatomic, strong, nullable) EXManagedAppSplashScreenViewProvider *managedAppSplashScreenViewProvider;
@property (nonatomic, strong, nullable) EXManagedAppSplashScreenViewController *managedSplashScreenController;

/*
 * This view is available in managed apps run in Expo Go only.
 * It is shown only before any managed app manifest is delivered by the app loader.
 */
@property (nonatomic, strong, nullable) EXAppLoadingCancelView *appLoadingCancelView;

@end

@implementation EXAppViewController

#pragma mark - Lifecycle

- (instancetype)initWithAppRecord:(EXKernelAppRecord *)record
{
  if (self = [super init]) {
    _appRecord = record;
    _isStandalone = [EXEnvironment sharedEnvironment].isDetached;
  }
  return self;
}

- (void)dealloc
{
  [self _invalidateRecoveryTimer];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
  [super viewDidLoad];

  // EXKernel.appRegistry.homeAppRecord does not contain any homeAppRecord until this point,
  // therefore we cannot move this property initialization to the constructor/initializer
  _isHomeApp = _appRecord == [EXKernel sharedInstance].appRegistry.homeAppRecord;

  // show LoadingCancelView in managed apps only
  if (!self.isStandalone && !self.isHomeApp) {
    self.appLoadingCancelView = [EXAppLoadingCancelView new];
    // if home app is available then LoadingCancelView can show `go to home` button
    if ([EXKernel sharedInstance].appRegistry.homeAppRecord) {
      self.appLoadingCancelView.delegate = self;
    }
    [self.view addSubview:self.appLoadingCancelView];
    [self.view bringSubviewToFront:self.appLoadingCancelView];
  }

  // show LoadingProgressWindow in the development client for all apps other than production home
  BOOL isProductionHomeApp = self.isHomeApp && ![EXEnvironment sharedEnvironment].isDebugXCodeScheme;
  self.appLoadingProgressWindowController = [[EXAppLoadingProgressWindowController alloc] initWithEnabled:!self.isStandalone && !isProductionHomeApp];

  // show SplashScreen in standalone apps and home app only
  // SplashScreen for managed is shown once the manifest is available
  if (self.isHomeApp) {
    EXHomeAppSplashScreenViewProvider *homeAppSplashScreenViewProvider = [EXHomeAppSplashScreenViewProvider new];
    [self _showSplashScreenWithProvider:homeAppSplashScreenViewProvider];
  } else if (self.isStandalone) {
    [self _showSplashScreenWithProvider:[EXSplashScreenViewNativeProvider new]];
  }

  self.view.backgroundColor = [UIColor whiteColor];
  _appRecord.appManager.delegate = self;
  self.isLoading = YES;
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  if (_appRecord && _appRecord.status == kEXKernelAppRecordStatusNew) {
    _appRecord.appLoader.delegate = self;
    _appRecord.appLoader.dataSource = _appRecord.appManager;
    [self refresh];
  }
}

- (BOOL)shouldAutorotate
{
  return YES;
}

- (void)viewWillLayoutSubviews
{
  [super viewWillLayoutSubviews];
  if (_appLoadingCancelView) {
    _appLoadingCancelView.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
  }
  if (_contentView) {
    _contentView.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
  }
}

- (void)viewWillDisappear:(BOOL)animated
{
  [_appLoadingProgressWindowController hide];
  [super viewWillDisappear:animated];
}

/**
 * Force presented view controllers to use the same user interface style.
 */
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated: (BOOL)flag completion:(void (^ __nullable)(void))completion
{
  [super presentViewController:viewControllerToPresent animated:flag completion:completion];
  [self _overrideUserInterfaceStyleOf:viewControllerToPresent];
}

/**
 * Force child view controllers to use the same user interface style.
 */
- (void)addChildViewController:(UIViewController *)childController
{
  [super addChildViewController:childController];
  [self _overrideUserInterfaceStyleOf:childController];
}

#pragma mark - Public

- (void)maybeShowError:(NSError *)error
{
  self.isLoading = NO;
  if ([self _willAutoRecoverFromError:error]) {
    return;
  }
  if (error && ![error isKindOfClass:[NSError class]]) {
#if DEBUG
    NSAssert(NO, @"AppViewController error handler was called on an object that isn't an NSError");
#endif
    return;
  }

  // we don't ever want to show any Expo UI in a production standalone app, so hard crash
  if ([EXEnvironment sharedEnvironment].isDetached && ![_appRecord.appManager enablesDeveloperTools]) {
    NSException *e = [NSException exceptionWithName:@"ExpoFatalError"
                                             reason:[NSString stringWithFormat:@"Expo encountered a fatal error: %@", [error localizedDescription]]
                                           userInfo:@{NSUnderlyingErrorKey: error}];
    @throw e;
  }

  NSString *domain = (error && error.domain) ? error.domain : @"";
  BOOL isNetworkError = ([domain isEqualToString:(NSString *)kCFErrorDomainCFNetwork] || [domain isEqualToString:NSURLErrorDomain] || [domain isEqualToString:EXNetworkErrorDomain]);

  if (isNetworkError) {
    // show a human-readable reachability error
    dispatch_async(dispatch_get_main_queue(), ^{
      [self _showErrorWithType:kEXFatalErrorTypeLoading error:error];
    });
  } else if ([domain isEqualToString:@"JSServer"] && [_appRecord.appManager enablesDeveloperTools]) {
    // RCTRedBox already handled this
  } else if ([domain rangeOfString:RCTErrorDomain].length > 0 && [_appRecord.appManager enablesDeveloperTools]) {
    // RCTRedBox already handled this
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self _showErrorWithType:kEXFatalErrorTypeException error:error];
    });
  }
}

- (void)refresh
{
  self.isLoading = YES;
  self.isBridgeAlreadyLoading = NO;
  [self _invalidateRecoveryTimer];
  [_appRecord.appLoader request];
}

- (void)reloadFromCache
{
  self.isLoading = YES;
  self.isBridgeAlreadyLoading = NO;
  [self _invalidateRecoveryTimer];
  [_appRecord.appLoader requestFromCache];
}

- (void)appStateDidBecomeActive
{
  dispatch_async(dispatch_get_main_queue(), ^{
    // Reset the root view background color and window color if we switch between Expo home and project
    [self _setBackgroundColor:self.view];
  });
}

- (void)appStateDidBecomeInactive
{
}

- (void)_rebuildBridge
{
  if (!self.isBridgeAlreadyLoading) {
    self.isBridgeAlreadyLoading = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self _overrideUserInterfaceStyleOf:self];
      [self _overrideAppearanceModuleBehaviour];
      [self _invalidateRecoveryTimer];
      [[EXKernel sharedInstance] logAnalyticsEvent:@"LOAD_EXPERIENCE" forAppRecord:self.appRecord];
      [self.appRecord.appManager rebuildBridge];
    });
  }
}

- (void)foregroundControllers
{
  if (_backgroundedControllers != nil) {
    __block UIViewController *parentController = self;

    [_backgroundedControllers enumerateObjectsUsingBlock:^(UIViewController * _Nonnull viewController, NSUInteger idx, BOOL * _Nonnull stop) {
      [parentController presentViewController:viewController animated:NO completion:nil];
      parentController = viewController;
    }];

    _backgroundedControllers = nil;
  }
}

- (void)backgroundControllers
{
  UIViewController *childController = [self presentedViewController];

  if (childController != nil) {
    if (_backgroundedControllers == nil) {
      _backgroundedControllers = [NSMutableArray new];
    }

    while (childController != nil) {
      [_backgroundedControllers addObject:childController];
      childController = childController.presentedViewController;
    }
  }
}

/**
 * In managed app we expect two kinds of manifest:
 * - optimistic one (served from cache)
 * - actual one served when app is fetched.
 * For each of them we should show SplashScreen,
 * therefore for any consecutive SplashScreen.show call we just reconfigure what's already visible.
 * In HomeApp or standalone apps this function is no-op as SplashScreen is managed differently.
 */
- (void)_showOrReconfigureManagedAppSplashScreen:(EXManifestsManifest *)manifest
{
  if (_isStandalone || _isHomeApp) {
    return;
  }
  if (!_managedAppSplashScreenViewProvider) {
    _managedAppSplashScreenViewProvider = [[EXManagedAppSplashScreenViewProvider alloc] initWithManifest:manifest];

    [self _showManagedSplashScreenWithProvider:_managedAppSplashScreenViewProvider];
  } else {
    [_managedAppSplashScreenViewProvider updateSplashScreenViewWithManifest:manifest];
  }
}

- (void)_showCachedExperienceAlert
{
  if (self.isStandalone || self.isHomeApp) {
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    UIAlertController *alert = [UIAlertController
                                alertControllerWithTitle:@"Using a cached project"
                                message:@"If you did not intend to use a cached project, check your network connection and reload."
                                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reload" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
      [self refresh];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Use cache" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  });
}

- (void)_setLoadingViewStatusIfEnabledFromAppLoader:(EXAppLoader *)appLoader
{
  if (appLoader.shouldShowRemoteUpdateStatus) {
    [self.appLoadingProgressWindowController updateStatus:appLoader.remoteUpdateStatus];
  } else {
    [self.appLoadingProgressWindowController hide];
  }
}

- (void)_showSplashScreenWithProvider:(id<EXSplashScreenViewProvider>)provider
{
  EXSplashScreenService *splashScreenService = (EXSplashScreenService *)[EXModuleRegistryProvider getSingletonModuleForClass:[EXSplashScreenService class]];

  // EXSplashScreenService presents a splash screen on a root view controller
  // at the start of the app. Since we want the EXAppViewController to manage
  // the lifecycle of the splash screen we need to:
  // 1. present the splash screen on EXAppViewController
  // 2. hide the splash screen of root view controller
  // Disclaimer:
  //  there's only one root view controller, but possibly many EXAppViewControllers
  //  (in Expo Go: one project -> one EXAppViewController)
  //  and we want to hide SplashScreen only once for the root view controller, hence the "once"
  static dispatch_once_t once;
  void (^hideRootViewControllerSplashScreen)(void) = ^void() {
    dispatch_once(&once, ^{
      UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
      [splashScreenService hideSplashScreenFor:rootViewController
                               successCallback:^(BOOL hasEffect){}
                               failureCallback:^(NSString * _Nonnull message) {
        EXLogWarn(@"Hiding splash screen from root view controller did not succeed: %@", message);
      }];
    });
  };

  EX_WEAKIFY(self);
  dispatch_async(dispatch_get_main_queue(), ^{
    EX_ENSURE_STRONGIFY(self);
    [splashScreenService showSplashScreenFor:self
                    splashScreenViewProvider:provider
                             successCallback:hideRootViewControllerSplashScreen
                             failureCallback:^(NSString *message){ EXLogWarn(@"%@", message); }];
  });
}

- (void)_showManagedSplashScreenWithProvider:(id<EXSplashScreenViewProvider>)provider
{

  EXSplashScreenService *splashScreenService = (EXSplashScreenService *)[EXModuleRegistryProvider getSingletonModuleForClass:[EXSplashScreenService class]];

  EX_WEAKIFY(self);
  dispatch_async(dispatch_get_main_queue(), ^{
    EX_ENSURE_STRONGIFY(self);

    UIView *rootView = self.view;
    UIView *splashScreenView = [provider createSplashScreenView];
    self.managedSplashScreenController = [[EXManagedAppSplashScreenViewController alloc] initWithRootView:rootView
                                                                                                 splashScreenView:splashScreenView];
    [splashScreenService showSplashScreenFor:self
                      splashScreenController:self.managedSplashScreenController
                             successCallback:^{}
                             failureCallback:^(NSString *message){ EXLogWarn(@"%@", message); }];
  });

}

- (void)hideLoadingProgressWindow
{
  [self.appLoadingProgressWindowController hide];
  if (self.managedSplashScreenController) {
    [self.managedSplashScreenController startSplashScreenVisibleTimer];
  }
}

#pragma mark - EXAppLoaderDelegate

- (void)appLoader:(EXAppLoader *)appLoader didLoadOptimisticManifest:(EXManifestsManifest *)manifest
{
  if (_appLoadingCancelView) {
    EX_WEAKIFY(self);
    dispatch_async(dispatch_get_main_queue(), ^{
      EX_ENSURE_STRONGIFY(self);
      [self.appLoadingCancelView removeFromSuperview];
      self.appLoadingCancelView = nil;
    });
  }
  [self _showOrReconfigureManagedAppSplashScreen:manifest];
  [self _setLoadingViewStatusIfEnabledFromAppLoader:appLoader];
  if ([EXKernel sharedInstance].browserController) {
    [[EXKernel sharedInstance].browserController addHistoryItemWithUrl:appLoader.manifestUrl manifest:manifest];
  }
  [self _rebuildBridge];
}

- (void)appLoader:(EXAppLoader *)appLoader didLoadBundleWithProgress:(EXLoadingProgress *)progress
{
  if (self->_appRecord.appManager.status != kEXReactAppManagerStatusRunning) {
    [self.appLoadingProgressWindowController updateStatusWithProgress:progress];
  }
}

- (void)appLoader:(EXAppLoader *)appLoader didFinishLoadingManifest:(EXManifestsManifest *)manifest bundle:(NSData *)data
{
  [self _showOrReconfigureManagedAppSplashScreen:manifest];
  [self _rebuildBridge];
  if (self->_appRecord.appManager.status == kEXReactAppManagerStatusBridgeLoading) {
    [self->_appRecord.appManager appLoaderFinished];
  }

  if (!appLoader.isUpToDate && appLoader.shouldShowRemoteUpdateStatus) {
    [self _showCachedExperienceAlert];
  }
}

- (void)appLoader:(EXAppLoader *)appLoader didFailWithError:(NSError *)error
{
  if (_appRecord.appManager.status == kEXReactAppManagerStatusBridgeLoading) {
    [_appRecord.appManager appLoaderFailedWithError:error];
  }
  [self maybeShowError:error];
}

- (void)appLoader:(EXAppLoader *)appLoader didResolveUpdatedBundleWithManifest:(EXManifestsManifest * _Nullable)manifest isFromCache:(BOOL)isFromCache error:(NSError * _Nullable)error
{
  [[EXKernel sharedInstance].serviceRegistry.updatesManager notifyApp:_appRecord ofDownloadWithManifest:manifest isNew:!isFromCache error:error];
}

#pragma mark - EXReactAppManagerDelegate

- (void)reactAppManagerIsReadyForLoad:(EXReactAppManager *)appManager
{
  UIView *reactView = appManager.rootView;
  reactView.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
  reactView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;


  [_contentView removeFromSuperview];
  _contentView = reactView;
  [self.view addSubview:_contentView];
  [self.view sendSubviewToBack:_contentView];
  [reactView becomeFirstResponder];

  // Set root view background color after adding as subview so we can access window
  [self _setBackgroundColor:reactView];
}

- (void)reactAppManagerStartedLoadingJavaScript:(EXReactAppManager *)appManager
{
  EXAssertMainThread();
  self.isLoading = YES;
}

- (void)reactAppManagerFinishedLoadingJavaScript:(EXReactAppManager *)appManager
{
  EXAssertMainThread();
  self.isLoading = NO;
  if ([EXKernel sharedInstance].browserController) {
    [[EXKernel sharedInstance].browserController appDidFinishLoadingSuccessfully:_appRecord];
  }
}

- (void)reactAppManagerAppContentDidAppear:(EXReactAppManager *)appManager
{
  EXSplashScreenService *splashScreenService = (EXSplashScreenService *)[EXModuleRegistryProvider getSingletonModuleForClass:[EXSplashScreenService class]];
  [splashScreenService onAppContentDidAppear:self];
}

- (void)reactAppManagerAppContentWillReload:(EXReactAppManager *)appManager {
  EXSplashScreenService *splashScreenService = (EXSplashScreenService *)[EXModuleRegistryProvider getSingletonModuleForClass:[EXSplashScreenService class]];
  [splashScreenService onAppContentWillReload:self];
}

- (void)reactAppManager:(EXReactAppManager *)appManager failedToLoadJavaScriptWithError:(NSError *)error
{
  EXAssertMainThread();
  [self maybeShowError:error];
}

- (void)reactAppManagerDidInvalidate:(EXReactAppManager *)appManager
{
}

- (void)errorViewDidSelectRetry:(EXErrorView *)errorView
{
  [self refresh];
}

#pragma mark - orientation

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
  if ([self shouldUseRNScreenOrientation]) {
    return [super supportedInterfaceOrientations];
  }

#if __has_include(<EXScreenOrientation/EXScreenOrientationRegistry.h>)
  EXScreenOrientationRegistry *screenOrientationRegistry = (EXScreenOrientationRegistry *)[EXModuleRegistryProvider getSingletonModuleForClass:[EXScreenOrientationRegistry class]];
  if (screenOrientationRegistry && [screenOrientationRegistry requiredOrientationMask] > 0) {
    return [screenOrientationRegistry requiredOrientationMask];
  }
#endif

  return [self orientationMaskFromManifestOrDefault];
}

- (BOOL)shouldUseRNScreenOrientation
{
  Class screenWindowTraitsClass = [self->_appRecord.appManager versionedClassFromString:@"RNSScreenWindowTraits"];
  if ([screenWindowTraitsClass respondsToSelector:@selector(shouldAskScreensForScreenOrientationInViewController:)]) {
    id<EXKernelRNSScreenWindowTraits> screenWindowTraits = (id<EXKernelRNSScreenWindowTraits>)screenWindowTraitsClass;
    return [screenWindowTraits shouldAskScreensForScreenOrientationInViewController:self];
  }
  return NO;
}

- (UIInterfaceOrientationMask)orientationMaskFromManifestOrDefault {
  if (_appRecord.appLoader.manifest) {
    NSString *orientationConfig = _appRecord.appLoader.manifest.orientation;
    if ([orientationConfig isEqualToString:@"portrait"]) {
      // lock to portrait
      return UIInterfaceOrientationMaskPortrait;
    } else if ([orientationConfig isEqualToString:@"landscape"]) {
      // lock to landscape
      return UIInterfaceOrientationMaskLandscape;
    }
  }
  // no config or default value: allow autorotation
  return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)traitCollectionDidChange:(nullable UITraitCollection *)previousTraitCollection {
  [super traitCollectionDidChange:previousTraitCollection];
  if ((self.traitCollection.verticalSizeClass != previousTraitCollection.verticalSizeClass)
      || (self.traitCollection.horizontalSizeClass != previousTraitCollection.horizontalSizeClass)) {

    #if __has_include(<EXScreenOrientation/EXScreenOrientationRegistry.h>)
      EXScreenOrientationRegistry *screenOrientationRegistryController = (EXScreenOrientationRegistry *)[EXModuleRegistryProvider getSingletonModuleForClass:[EXScreenOrientationRegistry class]];
      [screenOrientationRegistryController traitCollectionDidChangeTo:self.traitCollection];
    #endif
  }
}

#pragma mark - RCTAppearanceModule

/**
 * This function overrides behaviour of RCTAppearanceModule
 * basing on 'userInterfaceStyle' option from the app manifest.
 * It also defaults the RCTAppearanceModule to 'light'.
 */
- (void)_overrideAppearanceModuleBehaviour
{
  NSString *userInterfaceStyle = [self _readUserInterfaceStyleFromManifest:_appRecord.appLoader.manifest];
  NSString *appearancePreference = nil;
  if (!userInterfaceStyle || [userInterfaceStyle isEqualToString:@"light"]) {
    appearancePreference = @"light";
  } else if ([userInterfaceStyle isEqualToString:@"dark"]) {
    appearancePreference = @"dark";
  } else if ([userInterfaceStyle isEqualToString:@"automatic"]) {
    appearancePreference = nil;
  }
  RCTOverrideAppearancePreference(appearancePreference);
#if defined(INCLUDES_VERSIONED_CODE) && __has_include(<ABI43_0_0React/ABI43_0_0RCTAppearance.h>)
  ABI43_0_0RCTOverrideAppearancePreference(appearancePreference);
#endif

#if defined(INCLUDES_VERSIONED_CODE) && __has_include(<ABI42_0_0React/ABI42_0_0RCTAppearance.h>)
  ABI42_0_0RCTOverrideAppearancePreference(appearancePreference);
#endif
#if defined(INCLUDES_VERSIONED_CODE) && __has_include(<ABI41_0_0React/ABI41_0_0RCTAppearance.h>)
  ABI41_0_0RCTOverrideAppearancePreference(appearancePreference);
#endif
}

#pragma mark - user interface style

- (void)_overrideUserInterfaceStyleOf:(UIViewController *)viewController
{
  if (@available(iOS 13.0, *)) {
    NSString *userInterfaceStyle = [self _readUserInterfaceStyleFromManifest:_appRecord.appLoader.manifest];
    viewController.overrideUserInterfaceStyle = [self _userInterfaceStyleForString:userInterfaceStyle];
  }
}

- (NSString * _Nullable)_readUserInterfaceStyleFromManifest:(EXManifestsManifest *)manifest
{
  return manifest.userInterfaceStyle;
}

- (UIUserInterfaceStyle)_userInterfaceStyleForString:(NSString *)userInterfaceStyleString API_AVAILABLE(ios(12.0)) {
  if ([userInterfaceStyleString isEqualToString:@"dark"]) {
    return UIUserInterfaceStyleDark;
  }
  if ([userInterfaceStyleString isEqualToString:@"automatic"]) {
    return UIUserInterfaceStyleUnspecified;
  }
  return UIUserInterfaceStyleLight;
}

#pragma mark - root view and window background color

- (void)_setBackgroundColor:(UIView *)view
{
    NSString *backgroundColorString = [self _readBackgroundColorFromManifest:_appRecord.appLoader.manifest];
    UIColor *backgroundColor = [EXUtil colorWithHexString:backgroundColorString];

    if (backgroundColor) {
      view.backgroundColor = backgroundColor;
      // NOTE(brentvatne): it may be desirable at some point to split the window backgroundColor out from the
      // root view, we can do if use case is presented to us.
      view.window.backgroundColor = backgroundColor;
    } else {
      view.backgroundColor = [UIColor whiteColor];

      // NOTE(brentvatne): we used to use white as a default background color for window but this caused
      // problems when using form sheet presentation style with vcs eg: <Modal /> and native-stack. Most
      // users expect the background behind these to be black, which is the default if backgroundColor is nil.
      view.window.backgroundColor = nil;

      // NOTE(brentvatne): we may want to default to respecting the default system background color
      // on iOS13 and higher, but if we do make this choice then we will have to implement it on Android
      // as well. This would also be a breaking change. Leaaving this here as a placeholder for the future.
      // if (@available(iOS 13.0, *)) {
      //   view.backgroundColor = [UIColor systemBackgroundColor];
      // } else {
      //  view.backgroundColor = [UIColor whiteColor];
      // }
    }
}

- (NSString * _Nullable)_readBackgroundColorFromManifest:(EXManifestsManifest *)manifest
{
  return manifest.iosOrRootBackgroundColor;
}


#pragma mark - Internal

- (void)_showErrorWithType:(EXFatalErrorType)type error:(nullable NSError *)error
{
  EXAssertMainThread();
  _dtmLastFatalErrorShown = [NSDate date];
  if (_errorView && _contentView == _errorView) {
    // already showing, just update
    _errorView.type = type;
    _errorView.error = error;
  } {
    [_contentView removeFromSuperview];
    if (!_errorView) {
      _errorView = [[EXErrorView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height)];
      _errorView.delegate = self;
      _errorView.appRecord = _appRecord;
    }
    _errorView.type = type;
    _errorView.error = error;
    _contentView = _errorView;
    [self.view addSubview:_contentView];
    [[EXAnalytics sharedInstance] logErrorVisibleEvent];
  }
}

- (void)setIsLoading:(BOOL)isLoading
{
  if ([_appRecord.appManager enablesDeveloperTools] && _dtmLastFatalErrorShown) {
    if ([_dtmLastFatalErrorShown timeIntervalSinceNow] >= -kEXDevelopmentErrorCoolDownSeconds) {
      // we just showed a fatal error very recently, do not begin loading.
      // this can happen in some cases where react native sends the 'started loading' notif
      // in spite of a packager error.
      return;
    }
  }
  _isLoading = isLoading;
  EX_WEAKIFY(self);
  dispatch_async(dispatch_get_main_queue(), ^{
    EX_ENSURE_STRONGIFY(self);
    if (!isLoading) {
      [self.appLoadingProgressWindowController hide];
    }
  });
}

#pragma mark - error recovery

- (BOOL)_willAutoRecoverFromError:(NSError *)error
{
  if (![_appRecord.appManager enablesDeveloperTools]) {
    BOOL shouldRecover = [[EXKernel sharedInstance].serviceRegistry.errorRecoveryManager experienceShouldReloadOnError:_appRecord.scopeKey];
    if (shouldRecover) {
      [self _invalidateRecoveryTimer];
      _tmrAutoReloadDebounce = [NSTimer scheduledTimerWithTimeInterval:kEXAutoReloadDebounceSeconds
                                                                target:self
                                                              selector:@selector(refresh)
                                                              userInfo:nil
                                                               repeats:NO];
    }
    return shouldRecover;
  }
  return NO;
}

- (void)_invalidateRecoveryTimer
{
  if (_tmrAutoReloadDebounce) {
    [_tmrAutoReloadDebounce invalidate];
    _tmrAutoReloadDebounce = nil;
  }
}

#pragma mark - EXAppLoadingCancelViewDelegate

- (void)appLoadingCancelViewDidCancel:(EXAppLoadingCancelView *)view {
  if ([EXKernel sharedInstance].browserController) {
    [[EXKernel sharedInstance].browserController moveHomeToVisible];
  }
}

@end

NS_ASSUME_NONNULL_END
