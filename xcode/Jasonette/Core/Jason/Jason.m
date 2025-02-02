//
//  Jason.m
//  Jasonette
//
//  Copyright © 2016 gliechtenstein. All rights reserved.
//
#import "Jason.h"
#import "JasonAppDelegate.h"
#import "NSData+ImageContentType.h"
#import "UIImage+GIF.h"

#import "JasonLogger.h"
#import "JasonNetworking.h"
#import "JasonNSClassFromString.h"

@interface Jason () {
    UINavigationController * navigationController;
    UITabBarController * tabController;
    REMenu * menu_component;
    JasonViewController * VC;

    NSString * title;
    NSString * desc;
    NSString * icon;

    id module;
    UIBarButtonItem * rightButtonItem;

    NSString * ROOT_URL;
    BOOL INITIAL_LOADING;

    BOOL isForeground;
    BOOL header_needs_refresh;

    NSDictionary * rendered_page;
    NSMutableDictionary * previous_footer;
    NSMutableDictionary * previus_header;

    AVCaptureVideoPreviewLayer * avPreviewLayer;
    NSMutableArray * queue;
    BOOL tabNeedsRefresh;
}

@end

@implementation Jason


#pragma mark - Jason Core initializers

+ (Jason *)client
{
    // This follows the singleton pattern
    static dispatch_once_t predicate = 0;
    static id sharedObject = nil;

    dispatch_once (&predicate, ^{
        DTLogInfo (@"Initializing Shared Client Object");
        sharedObject = [[self alloc] init];
    });

    return sharedObject;
}

- (id)init
{
    if (self = [super init]) {
        DTLogInfo (@"Initialing Jason Object");

        [[NSNotificationCenter defaultCenter]
         addObserver:self
            selector:@selector(onForeground)
                name:UIApplicationDidBecomeActiveNotification
              object:nil];

        [[NSNotificationCenter defaultCenter]
         addObserver:self
            selector:@selector(onBackground)
                name:UIApplicationDidEnterBackgroundNotification
              object:nil];

        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter]
         addObserver:self
            selector:@selector(onOrientationChange:)
                name:UIDeviceOrientationDidChangeNotification
              object:[UIDevice currentDevice]];

        self.searchMode = NO;
        self.services = [@{} mutableCopy];

        // Add observers for public API
        [[NSNotificationCenter defaultCenter]
         addObserver:self
            selector:@selector(notifySuccess:)
                name:@"Jason.success"
              object:nil];

        [[NSNotificationCenter defaultCenter]
         addObserver:self
            selector:@selector(notifyError:)
                name:@"Jason.error"
              object:nil];
    }

    return self;
}

- (JasonViewController *)getVC
{
    return VC;
}

#pragma mark - Jason Core API Notifications
- (void)notifySuccess:(NSNotification *)notification
{
    NSDictionary * args = notification.object;

    DTLogDebug (@"JasonCore: notifySuccess: %@", args);
    [[Jason client] success:args];
}

- (void)notifyError:(NSNotification *)notification
{
    NSDictionary * args = notification.object;

    DTLogWarning (@"JasonCore: notifyError: %@", args);
    [[Jason client] error:args];
}

- (void)loadViewByFile:(NSString *)url
               asFinal:(BOOL)final
                  onVC:(JasonViewController *)vc
{
    DTLogInfo (@"Loading View from URL %@ in View Controller", url);
    VC = vc;
    [self loadViewByFile:url asFinal:final];
}

- (void)loadViewByFile:(NSString *)url
               asFinal:(BOOL)final
{
    DTLogInfo (@"Loading View By File %@", url);

    id jsonResponseObject = [JasonHelper read_local_json:url];

    [self
     include:jsonResponseObject
           andCompletionHandler:^(id res)
               {
               id result = @{};

               if (res[@"$jason"]) {
                 result = res[@"$jason"];
               } else {
                 result = [JasonHelper loadErrorJson][@"$jason"];
                 DTLogError (@"Missing $jason property in \n%@\n\n", res);
               }

               self->VC.original = @{ @"$jason": result };
               [self drawViewFromJason:self->VC.original
                             asFinal:final];
           }];
}

#pragma mark - Jason Core API (USE ONLY THESE METHODS TO ACCESS Jason Core!)

- (void)start:(NSDictionary *)href
{
    /**************************************************
    *
    * Public API for initializing Jason
    * (ex) [[Jason client] start] from JasonAppDelegate
    *
    **************************************************/

    DTLogInfo (@"Starting App");

    JasonAppDelegate * app = (JasonAppDelegate *)[[UIApplication sharedApplication] delegate];
    NSDictionary * plist = [self getSettings];
    BOOL appendNonce = [plist[@"append_nonce_to_url"] boolValue];

    DTLogDebug ((appendNonce ? @"Nonce Activated" : @"Nonce Inactive"));

    ROOT_URL = plist[@"url"];
    NSURLComponents * components = [[NSURLComponents alloc]
                                    initWithURL:[NSURL URLWithString:ROOT_URL]
                         resolvingAgainstBaseURL           :NO];

    if (appendNonce && components) {
        if (![components.scheme isEqualToString:@"file"]) {
            DTLogDebug (@"Adding Nonce");

            NSURLQueryItem * nonce = [[NSURLQueryItem alloc]
                                      initWithName:@"jasonnonce" value:[NSString
                                                                        stringWithFormat:@"%u%f",
                                                                        arc4random_uniform (10000) + 1,
                                                                        CFAbsoluteTimeGetCurrent ()]];

            NSMutableArray * items = [NSMutableArray
                                      arrayWithCapacity:[components.queryItems count] + 1];
            [items addObject:nonce];

            [components setQueryItems:items];

            ROOT_URL = [components.URL absoluteString];
        } else {
            DTLogDebug (@"file:// scheme used. nonce not added.");
        }
    }

    DTLogDebug (@"Root Url %@", ROOT_URL);

    if (!ROOT_URL || [ROOT_URL isEqualToString:@""] || !components) {
        DTLogError (@"Url not found in settings.plist");
        DTLogInfo (@"Loading error.json");
        ROOT_URL = @"file://error.json";
    }

    INITIAL_LOADING = [plist[@"loading"] boolValue];
    DTLogDebug (@"Initial Loading: %@", (INITIAL_LOADING ? @"YES" : @"NO"));

    NSString * launch_url = plist[@"launch"];
    NSDictionary * launch = nil;

    if (launch_url && launch_url.length > 0) {
        DTLogDebug (@"Loading Preloader Launch Local Json %@", launch_url);
        launch = [JasonHelper read_local_json:launch_url];
    }

    // FLEX DEBUGGER
#if DEBUG

    if (plist[@"debug"] && [plist[@"debug"] boolValue]) {
        DTLogInfo (@"Loading Flex Debugger");
        [[FLEXManager sharedManager] showExplorer];
    }

#endif

    DTLogDebug (@"Creating View Controller");
    JasonViewController * vc = [[JasonViewController alloc] init];
    vc.url = ROOT_URL;
    vc.loading = INITIAL_LOADING;

    if (href) {
        DTLogDebug (@"Loading href %@", href);

        if (href[@"url"]) {
            vc.url = href[@"url"];
            DTLogDebug (@"With Url %@", vc.url);
        }

        if (href[@"options"]) {
            vc.options = href[@"options"];
            DTLogDebug (@"With Options %@", vc.options);
        }

        if (href[@"loading"]) {
            vc.loading = [href[@"loading"] boolValue];
            DTLogDebug (@"Is Loading? %d", vc.loading);
        }
    }

    if (launch) {
        DTLogDebug (@"SettingLaunch Preloader %@", launch);
        vc.preload = launch;
    }

    DTLogDebug (@"Loading View");
    vc.view.backgroundColor = [UIColor whiteColor];
    vc.extendedLayoutIncludesOpaqueBars = YES;

    DTLogDebug (@"Loading Navigation Controller");
    UINavigationController * nav = [[UINavigationController alloc] initWithRootViewController:vc];

    navigationController.navigationBar.shadowImage = [UIImage new];
    [navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    navigationController.navigationBar.translucent = NO;
    navigationController.navigationBar.backgroundColor = [UIColor clearColor];
    [JasonHelper setStatusBarBackgroundColor:[UIColor clearColor]];

    DTLogDebug (@"Loading TabBar Controller");
    UITabBarController * tab = [[UITabBarController alloc] init];
    tab.tabBar.backgroundColor = [UIColor whiteColor];
    tab.tabBar.shadowImage = [[UIImage alloc] init];
    tab.viewControllers = @[nav];
    tab.tabBar.hidden = YES;

    [tab setDelegate:self];

    DTLogDebug (@"Setting App Root Window");
    app.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    app.window.rootViewController = tab;

    DTLogDebug (@"Start Displaying");
    [app.window makeKeyAndVisible];
}

- (void)call:(NSDictionary *)action
{
    /**************************************************
    *
    * Invoke any action from any module
    * (ex) [[Jason client] call: @{@"type": @"$render"}]
    *
    **************************************************/
    [self call:action with:nil];
}

- (void)call:(id)action with:(NSDictionary *)data
{
    JasonMemory * memory = [JasonMemory client];

    // If executing, queue the action with "call" type
    if (memory.executing || !VC.events) {
        if (!queue) {
            queue = [[NSMutableArray alloc] init];
        }

        if (data) {
            [queue addObject:@{ @"action": action, @"data": data }];
        } else {
            [queue addObject:@{ @"action": action }];
        }

        return;
    }

    if (data && data.count > 0) {
        memory._register = data;
    }

    if ([action isKindOfClass:[NSDictionary class]]) {
        if ((NSDictionary *)action && ((NSDictionary *)action).count > 0) {
            memory._stack = action;
            [self exec];
        }
    } else {
        if (memory._register && memory._register.count > 0) {
            memory._stack = [self filloutTemplate:action withData:memory._register];
            [self exec];
        }
    }
}

- (void)success {
    /**************************************************
    *
    * ONLY Used from modules as a "success" callback when there's no return value.
    * When successful, return from any module by calling:
    *
    *  [[Jason client] success] ==> No return value
    *
    * When it returns with "success", the returned object will be automatically passed to the next action in the action call chain
    *
    **************************************************/
    [self success:@{}];
}

- (void)success:(id)result withOriginalUrl:(NSString *)url {
    if ([url isEqualToString:VC.url]) {
        [self success:result];
    }
}

- (void)success:(id)result {
    /**************************************************
    *
    * ONLY Used from Actions as a "success" callback when there's a return value.
    * When successful, return from any module by calling:
    *
    *  [[Jason client] success: result] ==> 'result' can be accessed using the variable '$jason' in the next action
    *
    * When it returns with "success", the returned object will be automatically passed to the next action in the action call chain
    *
    **************************************************/

    if (result) {
        if ([result isKindOfClass:[NSDictionary class]]) {
            if (((NSDictionary *)result).count > 0) {
                [JasonMemory client]._register = @{ @"$jason": result };
            } else {
                [JasonMemory client]._register = result;
            }
        } else {
            [JasonMemory client]._register = @{ @"$jason": result };
        }
    } else {
        [JasonMemory client]._register = @{ @"$jason": @{} };
    }

    [self networkLoading:NO with:nil];
    [self next];
}

- (void)error {
    /**************************************************
    *
    * ONLY Used from modules as a "error" callback.
    *
    *  [[Jason client] error] ==> No return value
    *
    **************************************************/
    [self error:@{}];
}

- (void)error:(id)result withOriginalUrl:(NSString *)url {
    if ([url isEqualToString:VC.url]) {
        [self error:result];
    }
}

- (void)error:(id)result {
    /**************************************************
    *
    * ONLY Used from modules as a "error" callback.
    *
    *  [[Jason client] error: result] ==> 'result' can be accessed in the error handling action using the variable '$jason'
    *
    **************************************************/

    if (result) {
        if ([result isKindOfClass:[NSDictionary class]]) {
            if (((NSDictionary *)result).count > 0) {
                [JasonMemory client]._register = @{ @"$jason": result };
            } else {
                [JasonMemory client]._register = result;
            }
        } else {
            [JasonMemory client]._register = @{ @"$jason": result };
        }
    } else {
        [JasonMemory client]._register = @{ @"$jason": @{} };
    }

    // In case oauth was in process, set it back to No
    self.oauth_in_process = NO;
    [self exception];
}

- (void)loading:(BOOL)turnon {
    /************************************************************************************
     *
     * Loading indicator
     *
     * pass YES to start loading
     * pass NO to end loading
     *
     **************************************************************************************/
    if (turnon) {
        [JDStatusBarNotification addStyleNamed:@"SBStyle1"
                                       prepare:^JDStatusBarStyle *(JDStatusBarStyle * style) {
                                           style.barColor = self->navigationController.navigationBar.backgroundColor;
                                           style.textColor = self->navigationController.navigationBar.tintColor;
                                           style.animationType = JDStatusBarAnimationTypeFade;
                                           return style;
                                       }];
        [JDStatusBarNotification showWithStatus:@"Loading" styleName:@"SBStyle1"];

        if (navigationController.navigationBar.barStyle == UIStatusBarStyleDefault) {
            [JDStatusBarNotification showActivityIndicator:YES indicatorStyle:UIActivityIndicatorViewStyleWhite];
        } else {
            [JDStatusBarNotification showActivityIndicator:YES indicatorStyle:UIActivityIndicatorViewStyleGray];
        }
    } else {
        if ([JDStatusBarNotification isVisible]) {
            [JDStatusBarNotification dismissAnimated:YES];
        }
    }
}

- (void)networkLoading:(BOOL)turnon with:(NSDictionary *)options; {
    dispatch_async (dispatch_get_main_queue (), ^{
        if (turnon && (options == nil || (options != nil && options[@"loading"] && [options[@"loading"] boolValue]))) {
            MBProgressHUD * hud = [MBProgressHUD showHUDAddedTo:self->VC.view animated:true];
            hud.animationType = MBProgressHUDAnimationFade;
            hud.userInteractionEnabled = NO;
        } else if (!turnon) {
            [MBProgressHUD hideHUDForView:self->VC.view animated:true];
        }
    });
}

# pragma mark - Jason public API (Can be accessed by calling {"type": "$(METHOD_NAME)"}
- (void)parse {
    NSDictionary * options = [self options];

    if (options[@"data"] && options[@"template"]) {
        id data = options[@"data"];
        NSString * template_name = options[@"template"];
        id template = VC.parser[template_name];
        id result = [JasonHelper parse:data with:template];
        [self success:result];
    } else {
        [self error:@{ @"message": @"Need to pass both data and template" }];
    }
}

- (void)href {
    JasonMemory * memory = [JasonMemory client];

    VC.callback = memory._stack;
    NSDictionary * href = [self options];

    memory._stack = @{}; // empty stack before visiting
    [self go:href];
}

- (void)search {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"focusSearch" object:nil];
}

- (void)blur {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"blur" object:nil];
}

- (void)home {
    [self unlock];
    [self go:@{ @"transition": @"root" }];
}

- (void)close {
    [self okWithMode:@"close"];
}

- (void)back {
    /********************************************************************************
    *
    * Go back to previous view
    *  if it's a modal, dismiss the modal
    *  if not, pop back
    *
    ********************************************************************************/
    [self unlock];

    if (VC.isModal) {
        [navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [navigationController popViewControllerAnimated:YES];
    }
}

- (void)cancel {
    [self unlock];
    [self ok];
}

- (void)okWithMode:(NSString *)mode {
    // When user decides to close on intro without "Open"ing, should respect the decision and
    // remove local_jason
    NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];

    if ([defaults valueForKey:@"local_jason"]) {
        [defaults removeObjectForKey:@"local_jason"];
        [defaults synchronize];
    }

    // Dismiss Keyboard
    [[NSNotificationCenter defaultCenter] postNotificationName:@"dismissSearchInput" object:nil];
    [VC.view endEditing:YES];

    // Act and close
    JasonMemory * memory = [JasonMemory client];

    if (memory._stack && memory._stack.count > 0) {
        memory.need_to_exec = YES;

        if (self.options && self.options.count > 0) {
            memory._register = @{ @"$jason": self.options };
        }
    } else {
        [self unlock];
    }

    if (menu_component) {
        if ([menu_component isOpen]) {
            [menu_component close];
        }
    }

    [navigationController setToolbarHidden:YES];

    if ([mode isEqualToString:@"close"]) {
        [navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        if (VC.isModal) {
            [navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        } else {
            [navigationController popViewControllerAnimated:YES];
        }
    }
}

- (void)ok {
    [self okWithMode:@"normal"];
}

- (void)ok:(NSDictionary *)data {
    JasonMemory * memory = [JasonMemory client];

    if (memory._stack && memory._stack.count > 0) {
        if (data && data.count > 0) {
            [memory set_register:data];
        }
    }

    [self ok];
}

- (void)set {
    NSDictionary * kv = [self options];

    for (NSString * key in kv) {
        VC.form[key] = kv[key];
    }

    [self success];
}

- (void)menu {
    if (menu_component) {
        if ([menu_component isOpen]) {
            [menu_component close];
            return;
        }
    }

    JasonMemory * memory = [JasonMemory client];

    NSDictionary * options = memory._stack[@"options"];

    if (!options) {
        return;
    }

    NSArray * items = options[@"items"];

    if (items && items.count > 0) {
        NSMutableArray * menu_item_array = [[NSMutableArray alloc] init];
        UIColor * backgroundColor = navigationController.navigationBar.barTintColor;
        UIColor * foregroundColor = navigationController.navigationBar.tintColor;

        for (NSDictionary * item in items) {
            NSString * itemtitle = item[@"text"];
            NSString * subtitle = @"";
            NSDictionary * item_action = item[@"action"];
            NSDictionary * item_href = item[@"href"];
            REMenuItem * menuItem = [[REMenuItem alloc] initWithTitle:itemtitle
                                                             subtitle:subtitle
                                                                image:nil
                                                     highlightedImage:nil
                                                               action:^(REMenuItem * item) {
                                                                   [self->menu_component close];

                                                                   if (item_action) {
                                                                       [memory set_stack:item_action];
                                                                       [self exec];
                                                                   } else if (item_href) {
                                                                       [self go:item_href];
                                                                   }
                                                               }];

            menuItem.backgroundColor = backgroundColor;
            menuItem.textColor = foregroundColor;
            menuItem.font = [UIFont fontWithName:@"HelveticaNeue-CondensedBold" size:14.0];
            menuItem.separatorColor = menuItem.backgroundColor;
            [menu_item_array addObject:menuItem];
        }

        menu_component = [[REMenu alloc] initWithItems:menu_item_array];
        menu_component.backgroundColor = backgroundColor;
        menu_component.borderColor = backgroundColor;
        menu_component.shadowRadius = 0.0;
        menu_component.separatorHeight = 0.0;
        menu_component.itemHeight = 50.0;
        menu_component.animationDuration = 0.1;
        [menu_component showFromNavigationController:navigationController];
    }
}

- (void)lambda {
    /*
     *
     # LAMBDA - Functional Programming for Actions
     #  Call an action by name, with arguments. Wait for it to finish. And continue on with its return value.
     #
     # How it works
     # 1. Calls another action by name
     # 2. Can also pass arguments via `options`, which will be interpreted as `$jason` in the callee action
     # 2. Waits for the callee action to return via `$return.success` or `$return.error`
     # 3. The Callee action can return using the `$return.success` or `$return.error` actions.
     # 4. `$return.success` calls the caller action's `success` action with return value. The caller action picks up where it left off and continues walking down the `success` action call chain.
     # 4. `$return.error` calls the caller action's `error` action with return value. The caller action picks up where it left off and continues walking down the `error` action call chain.
     #
     # Example 1: Basic lambda (Same as trigger)
     # {
     # "type": "$lambda",
     # "options": {
     # "name": "fetch"
     # }
     # }
     #
     #
     # Example 2: Basic lambda with success/error handlers
     # {
     # "type": "$lambda",
     # "options": {
     # "name": "fetch"
     # }
     # "success": {
     # "type": "$render"
     # },
     # "error": {
     # "type": "$util.toast",
     # "options": {
     # "text": "Error"
     # }
     # }
     # }
     #
     #
     # Example 3: Passing arguments
     # {
     # "type": "$lambda",
     # "options": {
     # "name": "fetch",
     # "options": {
     # "url": "https://www.jasonbase.com/things/73g"
     # }
     # },
     # "success": {
     # "type": "$render"
     # },
     # "error": {
     # "type": "$util.toast",
     # "options": {
     # "text": "Error"
     # }
     # }
     # }
     #
     # Example 4: Using the previous action's return value
     #
     # {
     # "type": "$network.request",
     # "options": {
     # "url": "https://www.jasonbase.com/things/73g"
     # },
     # "success": {
     # "type": "$lambda",
     # "options": {
     # "name": "draw"
     # },
     # "success": {
     # "type": "$render"
     # },
     # "error": {
     # "type": "$util.toast",
     # "options": {
     # "text": "Error"
     # }
     # }
     # }
     # }
     #
     # Example 5: Using the previous action's return value as well as custom options
     #
     # {
     # "type": "$network.request",
     # "options": {
     # "url": "https://www.jasonbase.com/things/73g"
     # },
     # "success": {
     # "type": "$lambda",
     # "options": {
     # "name": "draw",
     # "options": {
     # "p1": "another param",
     # "p2": "yet another param"
     # }
     # },
     # "success": {
     # "type": "$render"
     # },
     # "error": {
     # "type": "$util.toast",
     # "options": {
     # "text": "Error"
     # }
     # }
     # }
     # }
     #
     */








    /*
     # Example:
     # {
     # "type": "$lambda",
     # "options": {
     # "name": "draw",
     # "options": {
     # "p1": "another param",
     # "p2": "yet another param"
     # }
     # },
     # "success": {
     # "type": "$render"
     # },
     # "error": {
     # "type": "$util.toast",
     # "options": {
     # "text": "Error"
     # }
     # }
     # }
     #
     */

    NSDictionary * options = [self options];
    /*
     * options = {
     * "name": "draw",
     * "options": {
     * "p1": "another param",
     * "p2": "yet another param"
     * }
     * }
     */


    NSString * name = options[@"name"];

    /*
     * name = "draw"
     */

    if (name) {
        // options can be an array or an object
        id args = options[@"options"];
        /*
         * args = {
         * "p1": "another param",
         * "p2": "yet another param"
         * }
         */
        JasonMemory * memory = [JasonMemory client];

        // set register
        if (args) {
            args =  [self filloutTemplate:args withData:memory._register];
            memory._register = @{ @"$jason": args };
        } else {
            // do nothing. keep the register and propgate
        }

        id lambda = [[VC valueForKey:@"events"] valueForKey:name];
        /*
         * lambda = [{
         * "{{#if $jason.items}}: {
         * "type": "$render",
         * "options": {
         * "data": "{{$jason.items}}"
         * }
         * }
         * }, {
         * "{{#else}}": {
         * "type": "$util.toast",
         * "options": {
         * "text": "Nothing to render"
         * }
         * }
         * }]
         */

        NSDictionary * resolved_lambda;

        if ([lambda isKindOfClass:[NSArray class]]) {
            resolved_lambda = [self filloutTemplate:lambda withData:memory._register];
        } else {
            resolved_lambda = lambda;
        }

        /*
         * resolved_lambda = {
         * "type": "$render"
         * }
         */

        // set current stack as the caller (before overwriting the stack)
        memory._caller = [memory._stack copy];

        // set stack
        memory._stack = resolved_lambda;

        // exec
        [self exec];
    } else {
        [self error];
    }
}

- (void)render {
    NSDictionary * stack = [JasonMemory client]._stack;

    /**************************************************
    *
    * PART 1: Prepare data by filling it in with all the variables
    *
    **************************************************/
    if ([JasonMemory client]._register && [JasonMemory client]._register.count > 0) {
        VC.data = [JasonMemory client]._register;
    }

    NSMutableDictionary * data_stub;

    if (VC.data) {
        data_stub = [VC.data mutableCopy];
    } else {
        data_stub = [[NSMutableDictionary alloc] init];
    }

    NSDictionary * kv = [self variables];

    for (NSString * key in kv) {
        data_stub[key] = kv[key];
    }

    if (stack[@"options"]) {
        if (!stack[@"options"][@"type"] || [stack[@"options"][@"type"] isEqualToString:@"json"]) {
            if (stack[@"options"][@"data"]) {
                /**************************************************
                *
                * You can pass in 'data' as one of the options for $render action, like so:
                *
                *    {
                *        "type": "$render",
                *        "options": {
                *           "data": {
                *               "results": [{
                *                   "id": "1",
                *                   "name": "tom"
                *               }, {
                *                   "id": "2",
                *                   "name": "kat"
                *               }]
                *            }
                *        }
                *   }
                *
                * 1. In this case we override the $jason value with the value inside `data`.
                *
                * In above example, The $jason value at the point of rendering becomes:
                *
                *   $jason = {
                *     "results": [{
                *       "id": "1",
                *       "name": "tom"
                *     }, {
                *       "id": "2",
                *       "name": "kat"
                *     }]
                *   }
                *
                * 2. The `data` can also be a template expression, in which case it will parse whatever data is being passed in to `$render` before using it as the data.
                *
                *   {
                *     "type": "$render",
                *     "options": {
                *       "data": {
                *         "results": {
                *               "{{#each $jason}}": {
                *             "id": "{{id}}",
                *             "name": "{{name}}"
                *           }
                *           }
                *       }
                *     }
                *   }
                *
                **************************************************/
                data_stub[@"$jason"] = [self filloutTemplate:stack[@"options"][@"data"] withData:data_stub];
            }
        }
    }

    VC.data = data_stub;

    /**************************************************
    *
    * PART 2: Get the template
    *
    **************************************************/

    // The default template is 'body'
    NSString * template_name = @"body";

    if (stack[@"options"] && stack[@"options"][@"template"]) {
        /**************************************************
        *
        * render can have 'template' attribute as an option, like so:
        *
        *    {
        *        "type": "$render",
        *        "options": {
        *           "template": "empty"
        *        }
        *    }
        *
        * In this case we use the specified 'empty' template instead of 'body'
        **************************************************/
        template_name = stack[@"options"][@"template"];
    }

    NSDictionary * body_parser = VC.parser[template_name];

    /**********************************************************************
    *
    * PART 3: Actually render the prepared data with the selected template
    *
    **********************************************************************/
    if (body_parser) {
        // if self.data is not empty, render
        if (stack[@"options"] && stack[@"options"][@"type"]) {
            if ([stack[@"options"][@"type"] isEqualToString:@"html"]) {
                rendered_page = [JasonHelper parse:data_stub ofType:@"html" with:body_parser];
            } else if ([stack[@"options"][@"type"] isEqualToString:@"xml"]) {
                rendered_page = [JasonHelper parse:data_stub ofType:@"xml" with:body_parser];
            } else {
                rendered_page = [JasonHelper parse:data_stub with:body_parser];
            }
        } else {
            rendered_page = [JasonHelper parse:data_stub with:body_parser];
        }

        if (rendered_page) {
            if (rendered_page[@"nav"]) {
                // Deprecated
                [self setupHeader:rendered_page[@"nav"]];
            } else if (rendered_page[@"header"]) {
                [self setupHeader:rendered_page[@"header"]];
            } else {
                [self setupHeader:nil];
            }

            if (rendered_page[@"footer"]) {
                [self setupTabBar:rendered_page[@"footer"][@"tabs"]];
            } else if (rendered_page[@"tabs"]) {
                // Deprecated
                [self setupTabBar:rendered_page[@"tabs"]];
            } else {
                [self setupTabBar:nil];
            }

            if (rendered_page[@"style"] && rendered_page[@"style"][@"background"]) {
                if ([rendered_page[@"style"][@"background"] isKindOfClass:[NSDictionary class]]) {
                    // Advanced background
                    // example:
                    //  "background": {
                    //      "type": "camera",
                    //      "options": {
                    //          ...
                    //      }
                    //  }
                    [self drawAdvancedBackground:rendered_page[@"style"][@"background"]];
                } else {
                    [self drawBackground:rendered_page[@"style"][@"background"]];
                }
            } else if (rendered_page[@"background"]) {
                if ([rendered_page[@"background"] isKindOfClass:[NSDictionary class]]) {
                    // advanced background
                    [self drawAdvancedBackground:rendered_page[@"background"]];
                } else {
                    [self drawBackground:rendered_page[@"background"]];
                }
            } else {
                [self drawBackground:@"#ffffff"];
            }
        }

        VC.rendered = rendered_page;

        if ([VC respondsToSelector:@selector(reload:final:)]) {
            [VC reload:rendered_page final:VC.contentLoaded];
        }

        // Cache the view after drawing
        [self cache_view];
    }

    [self success];
}

- (void)visit {
    JasonMemory * memory = [JasonMemory client];
    NSMutableDictionary * href = [[self options] mutableCopy];

    memory._stack = @{};
    NSString * url = href[@"url"];

    if (url && url.length > 0) {
        url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([url hasPrefix:@"data:"]) {
            url = url;
        } else if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) {
            url = url;
        } else {
            url = [NSString stringWithFormat:@"http://%@", url];
        }

        href[@"url"] = url;
        [self call:@{
             @"type": @"$href",
             @"options": href
        }];
    }
}

- (void)snapshot {
    if (self.avCaptureSession) {
        // don't snapshot when camera is running
        [[Jason client] error];
    } else {
        UIImage * image = [JasonHelper takescreenshot];
        NSData * imageData = UIImageJPEGRepresentation (image, 1.0);
        NSString * contentType = @"image/jpeg";
        NSString * dataFormatString = @"data:image/jpeg;base64,%@";
        NSString * base64data = [imageData base64EncodedStringWithOptions:0];
        NSString * dataString = [NSString stringWithFormat:dataFormatString, base64data];
        NSURL * dataURI = [NSURL URLWithString:dataString];
        [[Jason client] success:@{ @"data": base64data, @"data_uri": dataURI.absoluteString, @"content_type": contentType }];
    }
}

- (void)scroll {
    if (self.options && self.options[@"position"]) {
        NSString * position = self.options[@"position"];

        if ([position isEqualToString:@"top"]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"scrollToTop" object:nil userInfo:nil];
        } else if ([position isEqualToString:@"bottom"]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"scrollToBottom" object:nil userInfo:nil];
        }
    }

    [[Jason client] success];
}

# pragma mark - View initialization & teardown

- (void)         include:(id)json
    andCompletionHandler:(void (^)(id obj))callback
{
    DTLogInfo (@"Include Json");
    NSString * j = [JasonHelper stringify:json];

    // 1. Extract "@": "path@URL" patterns and create an array from the URLs
    // 2. Make concurrent requests to each item in the array
    // 3. Store each result under "[URL]" key
    // 4. Whenever we need to process JSON and encouter the "@" : "path@URL" pattern, we look into the "[URL]" value and parse it using path (if it exists)
    NSError * regexError = nil;

    // The pattern leaves out any url that starts with "$" because that will be handled by resolve_local_reference
    NSString * pattern = @"\"([+@])\"[ ]*:[ ]*\"([^$\"@]+@)?([^$\"]+)\"";

    NSMutableSet * urlSet = [NSMutableSet new];
    NSRegularExpression * regex = [NSRegularExpression
                                   regularExpressionWithPattern:pattern
                                                        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                          error:&regexError];

    if (regexError) {
        DTLogWarning (@"Regex Error in Extracting URL pattern %@ error %@", pattern, regexError);
    }

    NSArray * matches = [regex matchesInString:j
                                       options:NSMatchingWithoutAnchoringBounds
                                         range:NSMakeRange (0, j.length)];

    for (int i = 0; i < matches.count; i++) {
        NSTextCheckingResult * match = matches[i];
//        // Unused for now. Maybe become handy in the future
//        NSRange group1 = [match rangeAtIndex:1];
//        NSRange group2 = [match rangeAtIndex:2];
//        if(group1.length > 0)
//        {
//            DTLogDebug(@"Matches Group 1 %@", group1);
//        }
//
//        if(group2.length > 0)
//        {
//            // Group2 is for path
//            DTLogDebug(@"Matches Group 2 %@", group2);
//        }
        NSRange group3 = [match rangeAtIndex:3];

        if (group3.length > 0) {
            // Group 3 is for the URL
            NSString * url = [j substringWithRange:group3];

            if (!VC.requires[url]) {
                DTLogDebug (@"Adding object to url set %@", url);
                [urlSet addObject:url];
            }
        }
    }

    // 1. Create a dispatch_group
    if (urlSet.count > 0) {
        dispatch_group_t requireGroup = dispatch_group_create ();

        for (NSString * url in urlSet) {
            // 2. Enter dispatch_group
            dispatch_group_enter (requireGroup);

            // 3. Check if local
            if ([url hasPrefix:@"file://"]) {
                DTLogDebug (@"%@ is local file", url);
                NSString * resourcePath = [[NSBundle mainBundle] resourcePath];
                NSString * webrootPath = [resourcePath stringByAppendingPathComponent:@""];
                NSString * loc = @"file:/";

                NSString * jsonFile = [url
                                       stringByReplacingOccurrencesOfString:loc
                                                                 withString:webrootPath];

                NSFileManager * fileManager = [NSFileManager defaultManager];

                if ([fileManager fileExistsAtPath:jsonFile]) {
                    NSError * error = nil;
                    NSInputStream * inputStream = [[NSInputStream alloc] initWithFileAtPath:jsonFile];
                    [inputStream open];

                    id jsonResponseObject = [NSJSONSerialization
                                             JSONObjectWithStream:inputStream
                                                          options:kNilOptions
                                                            error:&error];

                    if (error) {
                        DTLogError (@"Failed to Parse Local Json %@", error);
                        jsonResponseObject = @{};
                    }

                    VC.requires[url] = jsonResponseObject;
                    [inputStream close];
                }

                dispatch_group_leave (requireGroup);
            } else {
                // 4. Setup networking
                DTLogDebug (@"Fetching %@ from Network", url);
                AFHTTPSessionManager * manager = [JasonNetworking manager];
                AFJSONResponseSerializer * jsonResponseSerializer = [JasonNetworking serializer];

                NSMutableSet * jsonAcceptableContentTypes = [NSMutableSet
                                                             setWithSet:jsonResponseSerializer.acceptableContentTypes];

                [jsonAcceptableContentTypes addObject:@"text/plain"];
                [jsonAcceptableContentTypes addObject:@"text/html"];
                [jsonAcceptableContentTypes addObject:@"application/json"];
                [jsonAcceptableContentTypes addObject:@"application/vnd.api+json"];

                for (NSString * contentType in [JasonNetworking acceptedContentTypes]) {
                    [jsonAcceptableContentTypes addObject:contentType];
                }

                jsonResponseSerializer.acceptableContentTypes = jsonAcceptableContentTypes;
                manager.responseSerializer = jsonResponseSerializer;

                // 5. Attach session
                NSDictionary * session = [JasonHelper sessionForUrl:url];

                if (session && session.count > 0 && session[@"header"]) {
                    for (NSString * key in session[@"header"]) {
                        [manager.requestSerializer
                         setValue:session[@"header"][key]
                                                   forHTTPHeaderField:key];
                    }
                }

                NSDictionary * headers = [JasonNetworking headers];

                for (NSString * key in headers) {
                    [manager.requestSerializer
                     setValue:headers[key]
                                           forHTTPHeaderField:key];
                }

                NSMutableDictionary * parameters = [@{} mutableCopy];

                if (session && session.count > 0 && session[@"body"]) {
                    for (NSString * key in session[@"body"]) {
                        parameters[key] = session[@"body"][key];
                    }
                }

                // 6. Start request
#pragma message "Start Request in Include"
                [manager   GET:url
                    parameters:parameters
                       headers:nil
                      progress:^(NSProgress * _Nonnull downloadProgress) { }
                       success:^(NSURLSessionDataTask * _Nonnull task, id _Nullable responseObject)
                           {
                           self->VC.requires[url] = responseObject;
                           dispatch_group_leave (requireGroup);
                       }
                       failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error)
                           {
                           DTLogWarning (@"Error Fetching JSON From Url %@ %@", url, error);
                           self->VC.requires[url] = @{};
                           dispatch_group_leave (requireGroup);
                       }];
            }
        }

        DTLogDebug (@"Remote References Detected");
        dispatch_group_notify (requireGroup, dispatch_get_main_queue (), ^{
            id resolved = [self resolve_remote_reference:j];
            [self
             include:resolved
                           andCompletionHandler:callback];
        });

        return;
    }

    DTLogDebug (@"Local References Detected");
    id resolved = [self resolve_local_reference:j];
    callback (resolved);
}

#pragma mark - $require action
- (void)require
{
    DTLogInfo (@"Require Json");
    NSString * origin_url = VC.url;

    DTLogDebug (@"%@", origin_url);

    /*
     *
     * {
     * "type": "$require",
     * "options": {
     * "items": ["https://...", "https://...", ....],
     * "item": "https://...."
     * }
     * }
     *
     * Crawl all the items in the array and assign it to the key
     *
     */

    NSMutableSet * urlSet = [[NSMutableSet alloc] init];

    for (NSString * key in self.options) {
        if ([self.options[key] isKindOfClass:[NSArray class]]) {
            [urlSet addObjectsFromArray:self.options[key]];
        } else if ([self.options[key] isKindOfClass:[NSString class]]) {
            [urlSet addObject:self.options[key]];
        }
    }

    NSError * regexError;
    NSMutableDictionary * return_value = [[NSMutableDictionary alloc] init];
    dispatch_group_t requireGroup = dispatch_group_create ();

    for (NSString * url in urlSet) {
        NSRegularExpression * document_regex = [NSRegularExpression regularExpressionWithPattern:@"\\$document" options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:&regexError];
        NSArray * matches = [document_regex matchesInString:url options:NSMatchingWithoutAnchoringBounds range:NSMakeRange (0, url.length)];

        if (matches.count == 0) {
            // 2. Enter dispatch_group
            dispatch_group_enter (requireGroup);

            if ([url containsString:@"file://"]) {
                // local
                return_value[url] = [JasonHelper read_local_json:url];
                dispatch_group_leave (requireGroup);
            } else {
                // 3. Setup networking
                AFHTTPSessionManager * manager = [JasonNetworking manager];
                AFJSONResponseSerializer * jsonResponseSerializer = [JasonNetworking serializer];

                NSMutableSet * jsonAcceptableContentTypes = [NSMutableSet
                                                             setWithSet:jsonResponseSerializer.acceptableContentTypes];

                [jsonAcceptableContentTypes addObject:@"text/plain"];
                [jsonAcceptableContentTypes addObject:@"text/html"];
                [jsonAcceptableContentTypes addObject:@"application/json"];
                [jsonAcceptableContentTypes addObject:@"application/vnd.api+json"];

                for (NSString * contentType in [JasonNetworking acceptedContentTypes]) {
                    [jsonAcceptableContentTypes addObject:contentType];
                }

                jsonResponseSerializer.acceptableContentTypes = jsonAcceptableContentTypes;
                manager.responseSerializer = jsonResponseSerializer;

                // 4. Attach session
                NSDictionary * session = [JasonHelper sessionForUrl:url];

                if (session && session.count > 0 && session[@"header"]) {
                    for (NSString * key in session[@"header"]) {
                        [manager.requestSerializer
                         setValue:session[@"header"][key]
                                                   forHTTPHeaderField:key];
                    }
                }

                NSDictionary * headers = [JasonNetworking headers];

                for (NSString * key in headers) {
                    [manager.requestSerializer
                     setValue:headers[key]
                                           forHTTPHeaderField:key];
                }

                NSMutableDictionary * parameters = [@{} mutableCopy];

                if (session && session.count > 0 && session[@"body"]) {
                    for (NSString * key in session[@"body"]) {
                        parameters[key] = session[@"body"][key];
                    }
                }

                // 5. Start request
#pragma message "Start Request in Require"
                [manager   GET:url
                    parameters:parameters
                       headers:nil
                      progress:^(NSProgress * _Nonnull downloadProgress) { }
                       success:^(NSURLSessionDataTask * _Nonnull task, id _Nullable responseObject)
                           {
                           return_value[url] = responseObject;
                           dispatch_group_leave (requireGroup);
                       }
                       failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error)
                           {
                           DTLogError (@"Failed Requiring %@ %@", url, error);
                           dispatch_group_leave (requireGroup);
                       }];
            }
        }
    }

    dispatch_group_notify (requireGroup, dispatch_get_main_queue (), ^{
        NSMutableDictionary * dict = [@{} mutableCopy];

        for (NSString * key in self.options) {
            if ([self.options[key] isKindOfClass:[NSArray class]]) {
                NSMutableArray * items = [@[] mutableCopy];

                for (NSString * url in self.options[key]) {
                    if (return_value[url]) {
                        [items addObject:return_value[url]];
                    } else {
                        [items addObject:@""];
                    }
                }

                dict[key] = items;
            } else if ([self.options[key] isKindOfClass:[NSString class]]) {
                if (return_value[self.options[key]]) {
                    dict[key] = return_value[self.options[key]];
                } else {
                    dict[key] = @"";
                }
            }
        }

        // require could take a long time to finish, so we make sure at this point
        // we are looking at the same URL we began with
        [self success:dict withOriginalUrl:origin_url];
        [MBProgressHUD hideHUDForView:self->VC.view animated:true];
    });
}

#pragma mark - Mixin
- (id)resolve_remote_reference:(NSString *)json
{
    DTLogInfo (@"Remote Reference Mixin");
    DTLogDebug (@"Resolving Remote References For Json %@", json);
    
    NSError * error;
    // Mixins can be used with '@' or '+' symbol
    // Remote url with path - convert "@": "blah.blah@https://www.google.com" to "{{#include $root[\"https://www.google.com\"].blah.blah}}": {}
    // The pattern leaves out the pattern where it starts with "$" because that's a $document and will be resolved by resolve_local_reference
    NSString * remote_pattern_with_path = @"\"([+@])\"[ ]*:[ ]*\"(([^$\"@]+)(@))([^\"]+)\"";
    NSRegularExpression * remote_regex_with_path = [NSRegularExpression
                                                    regularExpressionWithPattern:remote_pattern_with_path
                                                                         options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                           error:&error];

    NSString * converted = [remote_regex_with_path
                            stringByReplacingMatchesInString:json
                                                     options:kNilOptions
                                                       range:NSMakeRange (0, json.length)
                                                withTemplate:@"\"{{#include \\$root[\\\\\"$5\\\\\"].$3}}\": {}"];

    // Remote url without path - convert "@": "https://www.google.com" to "{{#include $root[\"https://www.google.com\"]}}": {}
    // The pattern leaves out the pattern where it starts with "$" because that's a $document and will be resolved by resolve_local_reference
    NSString * remote_pattern_without_path = @"\"([+@])\"[ ]*:[ ]*\"([^$\"]+)\"";
    NSRegularExpression * remote_regex_without_path = [NSRegularExpression
                                                       regularExpressionWithPattern:remote_pattern_without_path
                                                                            options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                              error:&error];

    converted = [remote_regex_without_path
                 stringByReplacingMatchesInString:converted
                                          options:kNilOptions
                                            range:NSMakeRange (0, converted.length)
                                     withTemplate:@"\"{{#include \\$root[\\\\\"$2\\\\\"]}}\": {}"];

    id tpl = [JasonHelper objectify:converted];

    NSMutableDictionary * refs = [VC.requires mutableCopy];

    refs[@"$document"] = VC.original;
    id include_resolved = [JasonParser parse:refs with:tpl];

    VC.original = include_resolved;
    return include_resolved;
}

- (id)resolve_local_reference:(NSString *)json
{
    DTLogInfo (@"Local Reference Mixin");
    DTLogDebug (@"Resolving Local References For Json %@", json);

    // Local - convert "@": "$document.blah.blah" to "{{#include $root.$document.blah.blah}}": {}
    NSError * error;
    NSString * local_pattern = @"\"[+@]\"[ ]*:[ ]*\"[ ]*(\\$document[^\"]*)\"";
    NSRegularExpression * local_regex = [NSRegularExpression
                                         regularExpressionWithPattern:local_pattern
                                                              options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                error:&error];

    NSString * converted = [local_regex
                            stringByReplacingMatchesInString:json
                                                     options:kNilOptions
                                                       range:NSMakeRange (0, json.length)
                                                withTemplate:@"\"{{#include \\$root.$1}}\": {}"];
    
    
    id tpl = [JasonHelper objectify:converted];

    NSMutableDictionary * refs = [VC.requires mutableCopy];

    
    refs[@"$document"] = VC.original;
    
    DTLogDebug(@"TPL %@ Refs", tpl, refs);

    id include_resolved = [JasonParser parse:refs with:tpl];

    VC.original = include_resolved;
    
    DTLogDebug(@"Resolved References %@", include_resolved);

    return include_resolved;
}

#pragma mark - Lifecycle
- (Jason *)detach:(JasonViewController *)viewController
{
    // Need to clean up before leaving the view
    DTLogDebug (@"Detaching View Controller");
    VC = (JasonViewController *)viewController;

    // Reset Timers
    DTLogDebug (@"Resetting Timers If Any");

    for (NSString * timer_name in VC.timers) {
        NSTimer * timer = VC.timers[timer_name];
        [timer invalidate];
        [VC.timers removeObjectForKey:timer_name];
    }

    // Reset Audios
    DTLogDebug (@"Resetting Audios If Any");

    for (NSString * audio_name in VC.audios) {
        FSAudioStream * audio = VC.audios[audio_name];
        [audio stop];
        [VC.audios removeObjectForKey:audio];
    }

    // Reset Video
    DTLogDebug (@"Resetting Videos If Any");

    for (AVPlayer * player in VC.playing) {
        [player pause];
    }

    [VC.playing removeAllObjects];

    [VC.view endEditing:YES];


    // Reset Agent
    DTLogDebug (@"Resetting Agent If Any");

    for (NSString * key in ((JasonViewController *)VC).agents) {
        JasonAgentService * agent = self.services[@"JasonAgentService"];

        if ([key isEqualToString:@"$webcontainer"]) {
            // Web container is a special case agent => because it may function as a full-fledged view of the app,
            // we can't just kill the entire thing just because the app transitioned from view A to B.
            // View A should always be ready when we come back from view B.
            DTLogDebug (@"$webcontainer found");

            if (VC.isMovingFromParentViewController || VC.isBeingDismissed) {
                // Web container AND coming back from the child view therefore it's ok to kill the child view's web container agent
                DTLogDebug (@"Web container AND coming back from the child view therefore it's ok to kill the child view's web container agent");
                [agent clear:key forVC:VC];
            } else {
                // Otherwise it could be:
                // 1. Going from view A to view B (Don't kill view A's agent)
                DTLogDebug (@"Going from view A to view B (Don't kill view A's agent)");
                DTLogDebug (@"Not clearing $webcontainer");
            }
        } else {
            DTLogDebug (@"Clearing Agent %@", key);
            [agent clear:key forVC:VC];
        }
    }

    DTLogDebug (@"Cleaning Up Memory");
    [JasonMemory client].executing = NO;

    return self;
}

- (Jason *)attach:(JasonViewController *)viewController {
    // When oauth is in process, let it do its job and don't interfere.
    if (self.oauth_in_process) {
        return self;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"dismissSearchInput" object:nil];

    VC = (JasonViewController *)viewController;
    navigationController = viewController.navigationController;

    tabController = navigationController.tabBarController;
    tabController.delegate = self;
    [tabController.tabBar setClipsToBounds:YES];

    // Only make the background white if it's being loaded modally
    // Setting tabbar white looks weird when transitioning via push
    if (VC.isModal) {
        tabController.tabBar.barTintColor = [UIColor whiteColor];
        tabController.tabBar.backgroundColor = [UIColor whiteColor];
        tabController.tabBar.shadowImage = [[UIImage alloc] init];
    }

    navigationController.navigationBar.backgroundColor = [UIColor clearColor];
    navigationController.navigationBar.shadowImage = [UIImage new];
    [navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];

    // Set the stylesheet
    if (VC.style) {
        JasonComponentFactory.stylesheet = [VC.style mutableCopy];
        JasonComponentFactory.stylesheet[@"$default"] = @{ @"color": VC.view.tintColor };
    }

    [self.avCaptureSession stopRunning];
    self.avCaptureSession = nil;

    if (self.services[@"JasonWebsocketService"]) {
        [self.services[@"JasonWebsocketService"] close];
    }

    if (!queue) {
        queue = [[NSMutableArray alloc] init];
    }

    JasonMemory * memory = [JasonMemory client];

    if (memory.executing) {
        // if an action is currently executing, don't do anything
    } else if (memory.need_to_exec) {
        // Check if there's any action left in the action call chain. If there is, execute it.

        if (VC.original && VC.original[@"$jason"] && VC.original[@"$jason"][@"head"]) {
            VC.agentReady = NO;
            [self setupHead:VC.original[@"$jason"][@"head"]];
        }

        // Header update (Bugfix for when coming back from an href)
        header_needs_refresh = YES;

        if (VC.rendered[@"nav"]) {
            // Deprecated
            [self setupHeader:VC.rendered[@"nav"]];
        } else if (VC.rendered[@"header"]) {
            [self setupHeader:VC.rendered[@"header"]];
        } else {
            [self setupHeader:nil];
        }

        // If there's a callback waiting to be executing for the current VC, set it as stack
        if (VC.callback) {
            // 1. Replace with VC.callback
            memory._stack = VC.callback;
        }

        if (memory._stack && memory._stack.count > 0) {
            [self next];
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"finishRefreshing" object:nil];
            [self reload];
        }

        memory.need_to_exec = NO;
    }
    // If there's nothing to execute, now it's time to display content
    else {
        VC.data = nil;

        /************************************
         * Setup head as quickly as possible
         * And set the headSetup flag to true, so that it doesn't try to set it up again later
         **************************************/
        if (VC.original && VC.original[@"$jason"] && VC.original[@"$jason"][@"head"]) {
            VC.agentReady = NO;
            [self setupHead:VC.original[@"$jason"][@"head"]];
        }

        /*********************************************************************************************************
         *
         * VC.rendered: contains the rendered Jason DOM if it's been dynamically rendered.
         *
         * If VC.rendered is not nil, it means it's been already fully rendered.
         *
         ********************************************************************************************************/
        if (VC.rendered && rendered_page) {
            /*********************************************************************************************************
             *
             * We need to redraw the already rendered final result instead of the pre-rendered markup
             *
             * For example, in: {"head": {"title": "{{$params.name}}", ...}}
             * It will draw "{{$params.name}}" as the title of the nav bar if we don't draw from the already rendered markup.
             *
             ********************************************************************************************************/
            if (VC.rendered[@"nav"]) {
                // Deprecated
                [self setupHeader:VC.rendered[@"nav"]];
            } else if (VC.rendered[@"header"]) {
                [self setupHeader:VC.rendered[@"header"]];
            } else {
                [self setupHeader:nil];
            }

            NSDictionary * old_tabs = nil;

            if (rendered_page[@"footer"] && rendered_page[@"footer"][@"tabs"]) {
                old_tabs = rendered_page[@"footer"][@"tabs"];
            } else if (rendered_page[@"tabs"]) {
                old_tabs = rendered_page[@"tabs"];
            }

            if (VC.rendered[@"footer"] && VC.rendered[@"footer"][@"tabs"]) {
                if (![old_tabs isEqualToDictionary:VC.rendered[@"footer"][@"tabs"]]) {
                    // Use this
                    [self setupTabBar:VC.rendered[@"footer"][@"tabs"]];
                }
            } else {
                // Deprecated
                if (![old_tabs isEqualToDictionary:VC.rendered[@"tabs"]]) {
                    [self setupTabBar:VC.rendered[@"tabs"]];
                }
            }

            // restart avCaptureSession if the background type is "camera"
            if (VC.rendered[@"style"] && VC.rendered[@"style"][@"background"]) {
                if ([VC.rendered[@"style"][@"background"] isKindOfClass:[NSString class]]) {
                    if ([VC.rendered[@"style"][@"background"] isEqualToString:@"camera"]) {
                        [self buildCamera:@{ @"type": @"camera" } forVC:VC];
                    }
                } else if ([VC.rendered[@"style"][@"background"] isKindOfClass:[NSDictionary class]]) {
                    NSString * type = VC.rendered[@"style"][@"background"][@"type"];

                    if ([type isEqualToString:@"camera"]) {
                        [self buildCamera:VC.rendered[@"style"][@"background"][@"options"] forVC:VC];
                    }
                }
            } else if (VC.rendered[@"background"]) {
                if ([VC.rendered[@"background"] isKindOfClass:[NSString class]]) {
                    if ([VC.rendered[@"background"] isEqualToString:@"camera"]) {
                        [self buildCamera:@{ @"type": @"camera" } forVC:VC];
                    }
                } else if ([VC.rendered[@"background"] isKindOfClass:[NSDictionary class]]) {
                    NSString * type = VC.rendered[@"background"][@"type"];

                    if ([type isEqualToString:@"camera"]) {
                        [self buildCamera:VC.rendered[@"background"][@"options"] forVC:VC];
                    }
                }
            }

            // set "rendered_page" to VC.rendered for cases when we're coming back from another view
            // so that rendered_page will be always in sync even when there is no $show handler to refresh the view.

            rendered_page = VC.rendered;

            // if the view gets updated inside onShow, the rendered_page will update automatically
            [self onShow];
        }
        /*********************************************************************************************************
         *
         * If VC.rendered is nil, it means the current view has been statically rendered. (no $render calls)
         *
         ********************************************************************************************************/
        else {
            /*********************************************************************************************************
             *
             * If content has been loaded already,
             *  1. redraw navbar
             *  2. re-setup event listener
             *
             ********************************************************************************************************/
            if (VC.contentLoaded) {
                // If content already loaded,
                // 1. just setup the navbar so the navbar will have the correct style
                // 2. trigger load events ($show or $load)
                [self setupHeader:VC.nav];
                [self onShow];
            }
            /*********************************************************************************************************
             *
             * If content has not been loaded yet, do a fresh reload
             *
             ********************************************************************************************************/
            else {
                if (VC.preload && VC.preload[@"style"] && VC.preload[@"style"][@"background"]) {
                    if ([VC.preload[@"style"][@"background"] isKindOfClass:[NSDictionary class]]) {
                        [self drawAdvancedBackground:VC.preload[@"style"][@"background"]];
                    } else {
                        [self drawBackground:VC.preload[@"style"][@"background"]];
                    }
                } else if (VC.preload && VC.preload[@"background"]) {
                    if ([VC.preload[@"background"] isKindOfClass:[NSDictionary class]]) {
                        [self drawAdvancedBackground:VC.preload[@"background"]];
                    } else {
                        [self drawBackground:VC.preload[@"background"]];
                    }
                }

                [self reload];
            }
        }
    }

    return self;
}

- (void)open {
    // First time visit (with the intro)
    VC.contentLoaded = NO;
    VC.rendered = nil;
    [self success];
}

- (void)flush {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [[SDImageCache sharedImageCache]clearMemory];
    [[SDImageCache sharedImageCache]clearDisk];
    [self success];
}

- (void)kill {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [self reset];
}

- (void)reset {
    // like render, but completely reset all data
    VC.contentLoaded = NO;
    VC.rendered = nil;

    dispatch_async (dispatch_get_main_queue (), ^{
        [self->VC viewDidLoad];
        [self->VC viewWillAppear:NO];
    });
}

# pragma mark - Template related
/****************************************************************************
*
* filloutTemplate: withData:
*
* 1. Takes any template expression
* 2. Fills it in with: the value passed in + environment values such as keys, cache, local variable, etc.
* 3. Retruns the instantiated result
*
****************************************************************************/
- (id)filloutTemplate:(id)template
             withData:(id)data
{
    DTLogInfo (@"Fill Out Template With Data");
    // Step 1. Take the passed in data and merge it with env variables ($get, $cache, $keys, $jason)
    NSMutableDictionary * data_stub = [data mutableCopy];
    NSDictionary * kv = [self variables];

    for (NSString * key in kv) {
        data_stub[key] = kv[key];
    }

    // Step 2. Fill out the stack with the prepared data_stub (completely filled out from above steps)
    id res = [JasonHelper parse:data_stub with:template];

    // Step 3. Return (after typecasting)
    if ([res isKindOfClass:[NSArray class]]) {
        return (NSArray *)res;
    } else {
        return (NSDictionary *)res;
    }
}

- (NSArray *)getKeys {
    /*********************************************************************************************************
     *
     * You can set the key globally on the app by changing "settings.plist" file.
     * Keys from the settings.plist overrides everything else from above.
     *
     ********************************************************************************************************/
    NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];
    NSDictionary * plist = [self getSettings];

    for (NSString * key in plist) {
        if (![key isEqualToString:@"url"]) {
            NSString * new_key = [NSString stringWithFormat:@"$keys.%@", key];
            dict[new_key] = plist[key];
        }
    }

    NSMutableArray * newKeys = [[NSMutableArray alloc] init];

    for (NSString * key in dict) {
        [newKeys addObject:@{ @"key": key, @"val": dict[key] }];
    }

    return [newKeys copy];
}

- (NSDictionary *)getSettings
{
    DTLogInfo (@"Getting settings");
    NSDictionary * infoPlistSettings = [[NSBundle mainBundle]
                                        objectForInfoDictionaryKey:@"settings"];

    if (infoPlistSettings) {
        // target's info.plist file contains customized settings
        DTLogDebug (@"Reading from settings object inside info.plist");
        return infoPlistSettings;
    }

    // settings not found in target's Info.plist - get from file
    DTLogDebug (@"Reading from settings.plist file");
    NSURL * file = [[NSBundle mainBundle]
                    URLForResource:@"settings"
                     withExtension:@"plist"];

    NSDictionary * settingsPlistSettings = [NSDictionary
                                            dictionaryWithContentsOfURL:file];

    return settingsPlistSettings;
}

- (NSDictionary *)getEnv {
    DTLogDebug (@"Getting ENV");

    NSMutableDictionary * dict = [@{} mutableCopy];
    NSURL * file = [[NSBundle mainBundle] URLForResource:@"Info" withExtension:@"plist"];
    NSDictionary * info_plist = [NSDictionary dictionaryWithContentsOfURL:file];

    dict[@"url_scheme"] = info_plist[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];

    NSDictionary * info = [[NSBundle mainBundle] infoDictionary];
    NSString * version = [info objectForKey:@"CFBundleShortVersionString"];
    NSString * build = [info objectForKey:(NSString *)kCFBundleVersionKey];

    dict[@"app"] = @{ @"build": build, @"version": version };

    CGRect bounds = [[UIScreen mainScreen] bounds];

    dict[@"device"] = @{
        @"uuid": [[[UIDevice currentDevice] identifierForVendor] UUIDString],
        @"width": @(bounds.size.width),
        @"height": @(bounds.size.height),
        @"os": @{
            @"name": [[[UIDevice currentDevice] systemName] lowercaseString],
            @"version": [[UIDevice currentDevice] systemVersion]
        },
        @"name": [[UIDevice currentDevice] name],
        @"model": @{
            @"name": [[UIDevice currentDevice] model],
            @"localized": [[UIDevice currentDevice] localizedModel]
        },
        @"language": [[NSLocale preferredLanguages] objectAtIndex:0]
    };

    NSURLComponents * components = [NSURLComponents componentsWithString:self->VC.url];
    NSMutableDictionary * params = [@{} mutableCopy];

    if (components.queryItems) {
        for (NSURLQueryItem * item in components.queryItems) {
            params[item.name] = item.value;
        }
    }

    dict[@"view"] = @{
        @"url": self->VC.url,
        @"params": params
    };

    return dict;
}

- (NSDictionary *)variables {
    DTLogDebug (@"Getting Variables");

    NSMutableDictionary * data_stub = [@{} mutableCopy];

    if (self->VC.data) {
        for (NSString * key in self->VC.data) {
            if (![key isEqualToString:@"$jason"]) {
                data_stub[key] = VC.data[key];
            }
        }
    }

    if (self->VC.form) {
        data_stub[@"$get"] = self->VC.form;
    } else {
        data_stub[@"$get"] = @{};
    }

    if (self->VC.options) {
        data_stub[@"$params"] = self->VC.options;
    } else {
        data_stub[@"$params"] = @{};
    }

    NSArray * keys = [self getKeys];

    if (keys && keys.count > 0) {
        NSMutableDictionary * dict = [@{} mutableCopy];

        for (NSDictionary * kv in keys) {
            NSString * key = kv[@"key"];
            NSArray * split = [key componentsSeparatedByString:@"."];

            if ([split count] == 2) {
                NSString * key_name = [split lastObject];
                NSString * val = kv[@"val"];
                dict[key_name] = val;
            }
        }

        if ([dict count] > 0) {
            data_stub[@"$keys"] = dict;
        } else {
            data_stub[@"$keys"] = @{};
        }
    }

    NSDictionary * env = [self getEnv];

    data_stub[@"$env"] = env;

    if (self->VC.current_cache) {
        if (self->VC.current_cache.count > 0) {
            data_stub[@"$cache"] = self->VC.current_cache;
        } else {
            data_stub[@"$cache"] = @{};
        }
    } else {
        // Fetch the cache from NSUserDefaults only the first time.
        // After this, VC.current_cache will update only when a $set action is called.
        NSString * normalized_url = [self->VC.url lowercaseString];
        self->VC.current_cache = [[NSUserDefaults standardUserDefaults] objectForKey:normalized_url];

        if (self->VC.current_cache && self->VC.current_cache.count > 0) {
            data_stub[@"$cache"] = self->VC.current_cache;
        } else {
            data_stub[@"$cache"] = @{};
        }
    }

    if (self.global) {
        data_stub[@"$global"] = self.global;
    } else {
        id data = [[NSUserDefaults standardUserDefaults] objectForKey:@"$global"];
        NSDictionary * dict;
        BOOL deprecated = ![data isKindOfClass:[NSData class]];

        if (data) {
            if (deprecated) {
                // string type (old version, will deprecate)
                dict = (NSDictionary *)data;
            } else {
                dict = (NSDictionary *)[NSKeyedUnarchiver unarchiveObjectWithData:data];
            }

            if (dict && dict.count > 0) {
                data_stub[@"$global"] = dict;
            } else {
                data_stub[@"$global"] = @{};
            }
        } else {
            data_stub[@"$global"] = @{};
        }
    }

    return data_stub;
}

# pragma mark - View rendering (high level)


/**
 * Redraws the view with the current json
 */
- (void)refresh
{
    NSDictionary * json = [self->VC.original mutableCopy];

    json[@"$jason"][@"body"][@"background"][@"com.jasonelle.state:stop-reloading"] = @YES;

    DTLogInfo (@"Redrawing View %@", json);

    [self
     drawViewFromJason:json
               asFinal:YES];
}

- (void)reload
{
    DTLogInfo (@"Reloading View");

    self->VC.data = nil;
    self->VC.form = [@{} mutableCopy];

    if (self->VC.url) {
        [self networkLoading:self->VC.loading with:nil];
        AFHTTPSessionManager * manager = [JasonNetworking manager];
        NSDictionary * session = [JasonHelper sessionForUrl:VC.url];

        // Set Header if specified  "header"
        NSDictionary * headers = self.options[@"header"];

        // legacy code : headers is deprecated
        if (!headers) {
            headers = self.options[@"headers"];
        }

        if (headers && headers.count > 0) {
            for (NSString * key in headers) {
                [manager.requestSerializer
                 setValue:headers[key]
                                   forHTTPHeaderField:key];
            }
        }

        if (session && session.count > 0 && session[@"header"]) {
            for (NSString * key in session[@"header"]) {
                [manager.requestSerializer
                 setValue:session[@"header"][key]
                                   forHTTPHeaderField:key];
            }
        }

        NSMutableDictionary * parameters = nil;

        if (self->VC.options[@"data"]) {
            parameters = [self->VC.options[@"data"] mutableCopy];
        } else {
            if (session && session.count > 0 && session[@"body"]) {
                parameters = [@{} mutableCopy];

                for (NSString * key in session[@"body"]) {
                    parameters[key] = session[@"body"][key];
                }
            }
        }

        if (self->VC.fresh) {
            DTLogDebug (@"Ignoring Cache Because `fresh` was enabled");
            [manager.requestSerializer
             setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];

            if (!parameters) {
                parameters = [@{} mutableCopy];
            }

            int timestamp = [[NSDate date] timeIntervalSince1970];
            parameters[@"timestamp"] = [NSString stringWithFormat:@"%d", timestamp];
        }

        self->VC.contentLoaded = NO;

        /**************************************************
         * Experimental : Offline handling
         * => Only load from cache initially if head contains "offline":"true"
         ***************************************************/

        NSString * normalized_url = [JasonHelper
                                     normalized_url:VC.url
                                         forOptions:VC.options];

        NSArray * paths = NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES);
        NSString * documentsDirectory = [paths objectAtIndex:0];
        NSString * path = [documentsDirectory stringByAppendingPathComponent:normalized_url];
        NSData * data = [NSData dataWithContentsOfFile:path];

        if (data && data.length > 0) {
            NSDictionary * responseObject = [NSKeyedUnarchiver unarchiveObjectWithData:data];

            if (responseObject && responseObject[@"$jason"] && responseObject[@"$jason"][@"head"] && responseObject[@"$jason"][@"head"][@"offline"]) {
                // get rid of $load and $show so they don't get triggered
                if (responseObject[@"$jason"][@"head"][@"actions"] && responseObject[@"$jason"][@"head"][@"actions"][@"$load"]) {
                    [responseObject[@"$jason"][@"head"][@"actions"] removeObjectForKey:@"$load"];
                }

                if (responseObject[@"$jason"][@"head"][@"actions"] && responseObject[@"$jason"][@"head"][@"actions"][@"$show"]) {
                    [responseObject[@"$jason"][@"head"][@"actions"] removeObjectForKey:@"$show"];
                }

                self->VC.offline = YES;
                [self drawViewFromJason:responseObject asFinal:NO];
            }
        }

        self->VC.requires = [@{} mutableCopy];

        /**************************************************
         * Handling data uri
         ***************************************************/
        if ([self->VC.url hasPrefix:@"data:application/json"]) {
            // if data uri, parse it into NSData
            NSURL * url = [NSURL URLWithString:self->VC.url];
            NSData * jsonData = [NSData dataWithContentsOfURL:url];
            NSError * error;

            self->VC.original = [NSJSONSerialization
                                 JSONObjectWithData:jsonData
                                            options:kNilOptions
                                              error:&error];

            if (error) {
                DTLogWarning (@"Error parsing json. %@ %@", self->VC.url, error);
            } else {
                [self drawViewFromJason:self->VC.original asFinal:YES];
            }
        } else if ([self->VC.url hasPrefix:@"file://"]) {
            [self loadViewByFile:self->VC.url asFinal:YES];
        }
        /************************************r**************
        * Normally urls are not in data-uri.
        ***************************************************/
        else {
            AFJSONResponseSerializer * jsonResponseSerializer = [JasonNetworking serializer];
            NSMutableSet * jsonAcceptableContentTypes = [NSMutableSet setWithSet:jsonResponseSerializer.acceptableContentTypes];

            // Assumes that content type is json, even the text/plain ones (Some hosting sites respond with data_type of text/plain even when it's actually a json, so we accept even text/plain as json by default)

            [jsonAcceptableContentTypes addObject:@"text/plain"];
            [jsonAcceptableContentTypes addObject:@"text/html"];
            [jsonAcceptableContentTypes addObject:@"application/json"];
            [jsonAcceptableContentTypes addObject:@"application/vnd.api+json"];
            [jsonAcceptableContentTypes addObject:@"application/hjson"];
            [jsonAcceptableContentTypes addObject:@"application/vnd.api+hjson"];

            for (NSString * contentType in [JasonNetworking acceptedContentTypes]) {
                [jsonAcceptableContentTypes addObject:contentType];
            }

            jsonResponseSerializer.acceptableContentTypes = jsonAcceptableContentTypes;

            manager.responseSerializer = jsonResponseSerializer;

#pragma message "Start Request in Reload"

            [manager   GET:self->VC.url
                parameters:parameters
                   headers:nil
                  progress:^(NSProgress * _Nonnull downloadProgress) { }
                   success:^(NSURLSessionDataTask * _Nonnull task, id _Nullable responseObject) {
                       // Ignore if the url is different
                       if (![JasonHelper isURL:task.originalRequest.URL
                                equivalentTo      :self->VC.url]) {
                         return;
                       }

                       self->VC.original = responseObject;

                       [self include:responseObject
                                          andCompletionHandler:^(id res)
                                              {
                                              dispatch_async (dispatch_get_main_queue (), ^{
                                              self->VC.contentLoaded = NO;

                                              self->VC.original = @{ @"$jason": res[@"$jason"] };
                                              [self drawViewFromJason:self->VC.original
                                                              asFinal:YES];
                                              });
                       }];
                   }
                   failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error)
                       {
                       if (!self->VC.offline) {
                         DTLogWarning (@"%@", error);
                         [[Jason client] loadViewByFile:@"file://error.json"
                                                asFinal:YES];
                         [[Jason client] call:@{
                              @"type": @"$util.alert",
                              @"options": @{
                                  @"title": @"Debug",
                                  @"description": [error localizedDescription]
                              }
                         }];
                       }
                   }];
        }
    }
}

- (void)drawViewFromJason:(NSDictionary *)jason
                  asFinal:(BOOL)final
{
    DTLogDebug (@"Drawing View From Jason");

    tabNeedsRefresh = YES;
    VC.tabNeedsRefresh = YES;

    NSDictionary * head = jason[@"$jason"][@"head"];

    NSDictionary * dom = jason[@"$jason"];

    /****************************************************************************
    *
    * Actual drawing starts here
    *
    ****************************************************************************/
    if (dom) {
        /****************************************************************************
        *
        * 1. Setup Head
        *
        ****************************************************************************/
        head = dom[@"head"];

        if (head) {
            [self setupHead:head];
        }

        /****************************************************************************
        *
        * 2. Setup Body
        *
        ****************************************************************************/
        NSDictionary * body = dom[@"body"];
        rendered_page = nil;

        if (body) {
            if (body[@"nav"]) {
                // Deprecated
                [self setupHeader:body[@"nav"]];
            } else if (body[@"header"]) {
                // Use this
                [self setupHeader:body[@"header"]];
            } else {
                [self setupHeader:nil];
            }

            if (body[@"footer"] && body[@"footer"][@"tabs"]) {
                // Use this
                [self setupTabBar:body[@"footer"][@"tabs"]];
            } else {
                // Deprecated
                [self setupTabBar:body[@"tabs"]];
            }

            // By default, "body" is the markup that will be rendered
            rendered_page = dom[@"body"];
        } else {
            // Don't remove the header and footer even if it doesn't exist yet
            // and let it be overridden in $render
        }

        /****************************************************************************
        *
        * If VC.parser exists, it means this view needs to be dynamically rendered
        * Therefore we override the rendered_page with a dynamically generated view
        *
        ****************************************************************************/
        if (VC.parser && VC.parser.count > 0) {
            NSDictionary * body_parser = VC.parser[@"body"];

            if (body_parser) {
                // parse the data with the template to dynamically build the view
                NSMutableDictionary * data_stub;

                if (VC.data) {
                    data_stub = [VC.data mutableCopy];
                    NSDictionary * kv = [self variables];

                    for (NSString * key in kv) {
                        data_stub[key] = kv[key];
                    }

                    rendered_page = [JasonHelper parse:data_stub with:body_parser];
                }
            }
        }

        if (rendered_page) {
            VC.rendered = rendered_page;
            // In case it's a different view, we need to reset

            if (rendered_page[@"style"] && rendered_page[@"style"][@"background"]) {
                if ([rendered_page[@"style"][@"background"] isKindOfClass:[NSDictionary class]]) {
                    // Advanced background
                    // example:
                    //  "background": {
                    //      "type": "camera",
                    //      "options": {
                    //          ...
                    //      }
                    //  }
                    [self drawAdvancedBackground:rendered_page[@"style"][@"background"]];
                } else {
                    [self drawBackground:rendered_page[@"style"][@"background"]];
                }
            } else if (rendered_page[@"background"]) {
                if ([rendered_page[@"background"] isKindOfClass:[NSDictionary class]]) {
                    // Advanced background
                    DTLogDebug (@"Detected Advanced Background");
                    [self drawAdvancedBackground:rendered_page[@"background"]];
                } else {
                    [self drawBackground:rendered_page[@"background"]];
                }
            } else {
                [self drawBackground:@"#ffffff"];
            }

            if (final) {
                if (rendered_page[@"nav"]) {
                    // Deprecated
                    [self setupHeader:rendered_page[@"nav"]];
                } else if (rendered_page[@"header"]) {
                    // Use thi
                    [self setupHeader:rendered_page[@"header"]];
                } else {
                    [self setupHeader:nil];
                }

                if (rendered_page[@"footer"] && rendered_page[@"footer"][@"tabs"]) {
                    // Use this
                    [self setupTabBar:rendered_page[@"footer"][@"tabs"]];
                } else {
                    // Deprecated
                    [self setupTabBar:rendered_page[@"tabs"]];
                }
            }

            if ([VC respondsToSelector:@selector(reload:final:)]) {
                [VC reload:rendered_page final:final];
            }

            // Cache the view after drawing
            if (final) {
                [self cache_view];
            }
        }

        if (head) {
            [self onLoad:final];
        }
    }

    [self loading:NO];
    [self networkLoading:NO with:nil];
}

- (void)drawAdvancedBackground:(NSDictionary *)bg {
    dispatch_async (dispatch_get_main_queue (), ^{
        [self drawAdvancedBackground:bg forVC:self->VC];
    });
}

- (void)drawAdvancedBackground:(NSDictionary *)bg forVC:(JasonViewController *)vc {
    NSString * type = bg[@"type"];

    if ([vc.background.payload[@"background"] isEqual:bg]) {
        return;
    }

    DTLogDebug (@"Drawing Advanced Background %@", bg);

    if (type) {
        if ([type isEqualToString:@"camera"]) {
            DTLogDebug (@"Drawing camera");
            NSDictionary * options = bg[@"options"];

            if (vc.background) {
                [vc.background removeFromSuperview];
                vc.background = nil;
            }

            vc.background = [[UIImageView alloc] initWithFrame:[UIScreen mainScreen].bounds];
            vc.background.payload = [@{ @"background": bg } mutableCopy];
            avPreviewLayer = nil;
            [self buildCamera:options forVC:vc];
        } else if ([type isEqualToString:@"html"]) {
            DTLogDebug (@"Drawing html");

            if (self.avCaptureSession) {
                [self.avCaptureSession stopRunning];
                self.avCaptureSession = nil;
            }

            if (vc.background && [vc.background isKindOfClass:[WKWebView class]]) {
                // don't do anything, reuse.
            } else {
                if (vc.background) {
                    [vc.background removeFromSuperview];
                    vc.background = nil;
                }
            }

            NSMutableDictionary * payload = [@{} mutableCopy];

            if (bg[@"url"]) {
                payload[@"url"] = bg[@"url"];
            } else if (bg[@"text"]) {
                payload[@"text"] = bg[@"text"];
            }

            if (bg[@"id"]) {
                payload[@"id"] = bg[@"id"];
            } else {
                // if no id is specified, just use the current url as the id
                payload[@"id"] = @"$webcontainer";
            }

            if (bg[@"action"]) {
                payload[@"action"] = bg[@"action"];
            }

            if (bg[@"com.jasonelle.state:stop-reloading"]) {
                payload[@"com.jasonelle.state:stop-reloading"] = @YES;
            }

            if (bg[@"options"]) {
                payload[@"options"] = bg[@"options"];
            }

            DTLogDebug (@"Loading Background with Payload %@", payload);

#pragma message "JasonAgentService Setup"
            JasonAgentService * agent = self.services[@"JasonAgentService"];

            vc.background = [agent setup:payload withId:payload[@"id"]];

            // Need to make the background transparent so that it doesn't flash white when first loading
            vc.background.opaque = NO;
            vc.background.backgroundColor = [UIColor clearColor];
            vc.background.hidden = NO;


#pragma message "Agent Webview frame"
            int height = [UIScreen mainScreen].bounds.size.height;
            int width = [UIScreen mainScreen].bounds.size.width;
            int x = 0;
            int y = 0;

            if (!tabController.tabBar.hidden) {
                height = height - tabController.tabBar.frame.size.height;
            }

            if (vc.composeBarView) {
                // footer.input exists
                height = height - vc.composeBarView.frame.size.height;
            }

            CGRect rect = CGRectMake (x, y, width, height);

//            if (@available(iOS 11, *)) {
//                // Take in consideration safe areas available in iOS 11
//                y = -vc.view.safeAreaInsets.top;
//                height = [UIScreen mainScreen].bounds.size.height +
//                    vc.view.safeAreaInsets.top +
//                    vc.view.safeAreaInsets.bottom;
//
//
//                x = -vc.view.safeAreaInsets.left;
//                width = [UIScreen mainScreen].bounds.size.width +
//                    vc.view.safeAreaInsets.left +
//                    vc.view.safeAreaInsets.right;
//
//                if (!tabController.tabBar.hidden) {
//                    height = height - tabController.tabBar.frame.size.height;
//                }
//
//                if (vc.composeBarView) {
//                    // footer.input exists
//                    height = height - vc.composeBarView.frame.size.height;
//                }
//
//                rect = CGRectMake (x, y, width, height);
//            }

            vc.background.frame = rect;

            UIProgressView * progressView = [vc.background viewWithTag:42];

            if (!progressView) {
                progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                [progressView setTag:42];
                [vc.background addSubview:progressView];
            }

            [progressView setTrackTintColor:[UIColor colorWithWhite:1.0f alpha:0.0f]];
            // agent top + navigation height + status bar size (fixed at 20)
            CGFloat navHeight = navigationController.navigationBar.frame.size.height;

            if (navigationController.navigationBar.hidden) {
                navHeight = 0;
            }

            [progressView setFrame:CGRectMake (0, vc.background.frame.origin.y + navHeight + 20, vc.background.frame.size.width, progressView.frame.size.height)];
            [progressView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin];

#pragma message "Webview Styles"

            if (bg[@"style"]) {
                if (bg[@"style"][@"background"]) {
                    vc.background.backgroundColor = [JasonHelper colorwithHexString:bg[@"style"][@"background"] alpha:1.0];
                }

                if (bg[@"style"][@"progress"]) {
                    progressView.tintColor = [JasonHelper colorwithHexString:bg[@"style"][@"progress"] alpha:1.0];
                }
            }
        }

        [vc.view addSubview:vc.background];
        [vc.view sendSubviewToBack:vc.background];
    }
}

- (void)buildCamera:(NSDictionary *)options forVC:(JasonViewController *)vc {
    DTLogDebug (@"Building Camera");


    NSError * error = nil;
    // Find back/front camera
    // based on options
    NSArray * devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevice * device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDevicePosition position = AVCaptureDevicePositionFront;

    if (options[@"device"] && [options[@"device"] isEqualToString:@"back"]) {
        position = AVCaptureDevicePositionBack;
    }

    for (AVCaptureDevice * d in devices) {
        if (d.position == position) {
            device = d;
        }
    }

    // Create session
    self.avCaptureSession = [[AVCaptureSession alloc] init];

    // Add input to the session
    AVCaptureDeviceInput * input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];

    if (error) {
        DTLogWarning (@"$vision: %@", error);
    }

    if (![self.avCaptureSession canAddInput:input]) {
        DTLogWarning (@"$vision: No camera found. Are you using a simulator?");
        DTLogDebug (@"Loading error.json");

        [self loadViewByFile:@"error.json" asFinal:YES];

        [self call:@{ @"type": @"$util.alert",
                      @"options": @{
                          @"description": @"No camera found."
        } }];
        return;
    }

    [self.avCaptureSession addInput:input];

    AVCaptureMetadataOutput * output = [[AVCaptureMetadataOutput alloc] init];

    if (![self.avCaptureSession canAddOutput:output]) {
        DTLogWarning (@"$vision: Can't add output");
        return;
    }

    [self.avCaptureSession addOutput:output];

    // Listen for different types of barcode detection
    [output setMetadataObjectsDelegate:self.services[@"JasonVisionService"] queue:dispatch_get_main_queue ()];
    [output setMetadataObjectTypes:output.availableMetadataObjectTypes];

    // Attach session preview layer to the background
    if (!avPreviewLayer) {
        avPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_avCaptureSession];
        avPreviewLayer.frame = vc.background.bounds;
        avPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [vc.background.layer addSublayer:avPreviewLayer];
    } else {
        [avPreviewLayer setSession:_avCaptureSession];
    }

    // Run
    [self.avCaptureSession startRunning];
    [self call:vc.events[@"$vision.ready"]];
}

- (void)drawBackground:(NSString *)bg {
    dispatch_async (dispatch_get_main_queue (), ^{
        [self drawBackground:bg forVC:self->VC];
    });
}

- (void)drawBackground:(NSString *)bg forVC:(JasonViewController *)vc {
    if ([bg isEqualToString:@"camera"]) {
        if (vc.background) {
            [vc.background removeFromSuperview];
            vc.background = nil;
        }

        vc.background = [[UIImageView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        [self buildCamera:@{ @"type": bg } forVC:vc];

        [vc.view addSubview:vc.background];
        [vc.view sendSubviewToBack:vc.background];
    } else if ([bg hasPrefix:@"http"] || [bg hasPrefix:@"data:"] || [bg hasPrefix:@"file"]) {
        if (self.avCaptureSession) {
            [self.avCaptureSession stopRunning];
            self.avCaptureSession = nil;
        }

        if (vc.background) {
            [vc.background removeFromSuperview];
            vc.background = nil;
        }

        vc.background = [[UIImageView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        vc.background.contentMode = UIViewContentModeScaleAspectFill;
        [vc.view addSubview:vc.background];
        [vc.view sendSubviewToBack:vc.background];

        if ([bg containsString:@"file://"]) {
            NSString * localImageName = [bg substringFromIndex:7];
            UIImage * localImage;

            // Get data for local file
            NSString * filePath = [[NSBundle mainBundle] pathForResource:localImageName ofType:nil];
            NSData * data = [[NSFileManager defaultManager] contentsAtPath:filePath];

            // Check for animated GIF
            NSString * imageContentType = [NSData sd_contentTypeForImageData:data];

            if ([imageContentType isEqualToString:@"image/gif"]) {
                localImage = [UIImage sd_animatedGIFWithData:data];
            } else {
                localImage = [UIImage imageNamed:localImageName];
            }

            [(UIImageView *)vc.background setImage:localImage];
        } else {
            UIImage * placeholder_image = [UIImage imageNamed:@"placeholderr"];
            [((UIImageView *)vc.background) sd_setImageWithURL:[NSURL URLWithString:bg]
                                              placeholderImage:placeholder_image
                                                     completed:^(UIImage * i, NSError * error, SDImageCacheType cacheType, NSURL * imageURL) {
                                                     }];
        }
    } else {
        if (self.avCaptureSession) {
            [self.avCaptureSession stopRunning];
            self.avCaptureSession = nil;
        }

        if (vc.background) {
            [vc.background removeFromSuperview];
            vc.background = nil;
        }

        vc.view.backgroundColor = [JasonHelper colorwithHexString:bg alpha:1.0];
    }
}

- (void)setupHead:(NSDictionary *)head {
    if (head) {
        // 1. Event handler
        NSDictionary * event_handlers = head[@"actions"];

        if (!event_handlers) {
            event_handlers = @{};
        }

        [VC setValue:event_handlers forKey:@"events"];

        // 2. data
        VC.data = nil;
        NSDictionary * data = head[@"data"];

        if (data) {
            VC.data = data;
        }

        NSDictionary * style = head[@"styles"];
        [VC setValue:style forKey:@"style"];

        // 3. agents
        if (!VC.agentReady) {
            // Agents must be setup ONLY once, AFTER the true view has finished loading.
            if (head[@"agents"] && [head[@"agents"] isKindOfClass:[NSDictionary class]] && [head[@"agents"] count] > 0) {
                for (NSString * key in head[@"agents"]) {
                    JasonAgentService * agent = self.services[@"JasonAgentService"];
                    [agent setup:head[@"agents"][key] withId:key];
                }
            }

            VC.agentReady = YES;
        }

        // 4. templates
        if (head[@"templates"]) {
            VC.parser = head[@"templates"];
        } else {
            VC.parser = nil;
        }
    }
}

# pragma mark - View rendering (nav)
- (void)setupHeader:(NSDictionary *)nav {
    [self setupHeader:nav forVC:VC];
}

- (void)setupHeader:(NSDictionary *)nav forVC:(JasonViewController *)v
{
    DTLogDebug (@"Setting Up Header Navigation");

    navigationController = v.navigationController;
    tabController = v.tabBarController;

    if (!nav) {
        DTLogDebug (@"No Navbar detected");
        navigationController.navigationBar.hidden = YES;
        return;
    }

    // if coming back from href, need_to_exec is true. In this case, shouldn't skip setupHeader.
    if (!header_needs_refresh) {
        if (v.rendered && rendered_page) {
            if (v.old_header && [[v.old_header description] isEqualToString:[nav description]]) {
                // if the header is the same as the value trying to set,
                if (rendered_page[@"header"] && [[rendered_page[@"header"] description] isEqualToString:[v.old_header description]]) {
                    // and if the currently visible rendered_page's header is the same as the VC's old_header, ignore.
                    return;
                }
            }
        }
    }

    header_needs_refresh = NO;

    if (nav) {
        v.old_header = [nav mutableCopy];
    }

    UIColor * background = [JasonHelper colorwithHexString:@"#ffffff" alpha:1.0];
    UIColor * color = [JasonHelper colorwithHexString:@"#000000" alpha:1.0];

    // Deprecated (using 'nav' instead of 'header')
    NSArray * items = nav[@"items"];

    if (items) {
        NSMutableDictionary * dict = [nav mutableCopy];
        [dict removeObjectForKey:@"items"];

        for (NSDictionary * item in items) {
            dict[item[@"type"]] = item;
        }

        nav = dict;
    }

    ////////////////////////////////////////////////////////////////

    if (!nav) {
        if (v.isModal || [tabController presentingViewController]) { // if the current tab bar was modally presented
            // if it's a modal, need to add X button to close
            nav = @{ @"left": @{} };
        } else {
            navigationController.navigationBar.shadowImage = [UIImage new];
            [navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
            navigationController.navigationBar.translucent = NO;
            [JasonHelper setStatusBarBackgroundColor:[UIColor clearColor]];

            navigationController.navigationBar.backgroundColor = background;
            navigationController.navigationBar.barTintColor = background;
            navigationController.navigationBar.tintColor = color;
            navigationController.navigationBar.titleTextAttributes = @{
                NSForegroundColorAttributeName: color,
                NSFontAttributeName: [UIFont
                                      fontWithName:@"HelveticaNeue-CondensedBold"
                                              size:18.0]
            };
            return;
        }
    }

    navigationController.navigationBar.barStyle = UIStatusBarStyleLightContent;
    navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: [UIFont
                              fontWithName:@"HelveticaNeue-CondensedBold"
                                      size:18.0]
    };
    navigationController.navigationBar.hidden = NO;

    if (nav[@"style"]) {
        NSDictionary * headStyle = nav[@"style"];

        if (headStyle[@"background"]) {
            background = [JasonHelper colorwithHexString:headStyle[@"background"] alpha:1.0];
        }

        if (headStyle[@"color"]) {
            color = [JasonHelper colorwithHexString:headStyle[@"color"] alpha:1.0];
        }

        navigationController.navigationBar.barStyle = UIStatusBarStyleLightContent;

        if (headStyle[@"theme"]) {
            navigationController.navigationBar.barStyle = UIStatusBarStyleDefault;
        }

#pragma message "Sets the Status Bar"

        if (headStyle[@"bar"]) {
            NSString * mode = [headStyle[@"bar"] lowercaseString];

            if ([mode isEqualToString:@"default"] ||
                [mode isEqualToString:@"dark"] ||
                [mode isEqualToString:@"black"] ||
                [mode isEqualToString:@"opaque"]) {
                DTLogDebug (@"Status Bar Default Color");
                navigationController.navigationBar.barStyle = UIStatusBarStyleDefault;
            } else if ([mode isEqualToString:@"light"] ||
                       [mode isEqualToString:@"white"]) {
                DTLogDebug (@"Status Bar White Color");
                navigationController.navigationBar.barStyle = UIStatusBarStyleLightContent;
            } else {
                // hidden
                // Note: To hide a status bar needs some special methods.
                DTLogDebug (@"Status Bar Hidden");
                navigationController.navigationBar.translucent = YES;
                [JasonHelper setStatusBarBackgroundColor:[UIColor clearColor]];
            }
        }

        navigationController.hidesBarsOnSwipe = NO;

        if (headStyle[@"shy"]) {
            navigationController.hidesBarsOnSwipe = YES;
        }

        NSString * font_name = @"HelveticaNeue-CondensedBold";
        NSString * font_size = @"18";

        if (headStyle[@"font"]) {
            font_name = headStyle[@"font"];
        }

        if (headStyle[@"size"]) {
            font_size = headStyle[@"size"];
        }

        navigationController.navigationBar.titleTextAttributes = @{
            NSForegroundColorAttributeName: color,
            NSFontAttributeName: [UIFont
                                  fontWithName:font_name
                                          size:[font_size integerValue]]
        };
    } else {
        navigationController.navigationBar.barStyle = UIStatusBarStyleLightContent;
        navigationController.hidesBarsOnSwipe = NO;
        NSString * font_name = @"HelveticaNeue-CondensedBold";
        NSString * font_size = @"18";
        navigationController.navigationBar.titleTextAttributes = @{
            NSForegroundColorAttributeName: color,
            NSFontAttributeName: [UIFont
                                  fontWithName:font_name
                                          size:[font_size integerValue]]
        };
    }

    NSDictionary * left_menu = nav[@"left"];
    NSDictionary * right_menu;

    NSArray * navComponents = nav[@"items"];

    if (navComponents) {
        for (NSDictionary * component in navComponents) {
            NSString * type = component[@"type"];

            if (type) {
                if ([type isEqualToString:@"menu"]) {
                    right_menu = component;
                    break;
                }
            }
        }
    }

    right_menu = nav[@"menu"];


    BBBadgeBarButtonItem * leftBarButton;

    if (!left_menu || [left_menu count] == 0) {
        // if the current view is in a modal AND is the rootviewcontroller of the navigationcontroller,
        // Add the X button. Otherwise, ignore this.
        if ([tabController presentingViewController]) { // if the current tab bar was modally presented
            if ([navigationController.viewControllers.firstObject isEqual:v]) {
                leftBarButton = [[BBBadgeBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(cancel)];
                [leftBarButton setTintColor:color];
            }
        }
    } else {
        if (left_menu[@"text"]) {
            NSString * left_menu_text = [left_menu[@"text"] description];
            UIButton * button = [[UIButton alloc] init];
            [button setTitle:left_menu_text forState:UIControlStateNormal];
            [button setTitle:left_menu_text forState:UIControlStateFocused];
            NSDictionary * style = left_menu[@"style"];

            if (style && style[@"color"]) {
                UIColor * c = [JasonHelper colorwithHexString:style[@"color"] alpha:1.0];
                [button setTitleColor:c forState:UIControlStateNormal];
            } else {
                [button setTitleColor:color forState:UIControlStateNormal];
            }

            CGFloat size = 14.0;
            NSString * font = @"HelveticaNeue";

            if (style[@"size"]) {
                size = [style[@"size"] floatValue];
            }

            if (style[@"font"]) {
                font = style[@"font"];
            }

            button.titleLabel.font = [UIFont fontWithName:font size:size];
            [button sizeToFit];
            [button addTarget:self action:@selector(leftMenu) forControlEvents:UIControlEventTouchUpInside];
            leftBarButton = [[BBBadgeBarButtonItem alloc] initWithCustomUIButton:button];
        } else {
            UIButton * btn =  [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake (0, 0, 20, 20);

            if (left_menu[@"image"]) {
                NSString * image_src = left_menu[@"image"];

                if ([image_src containsString:@"file://"]) {
                    UIImage * localImage = [UIImage imageNamed:[image_src substringFromIndex:7]];
                    [self setMenuButtonImage:localImage forButton:btn withMenu:left_menu];
                } else {
                    SDWebImageManager * manager = [SDWebImageManager sharedManager];
                    [manager downloadImageWithURL:[NSURL URLWithString:image_src]
                                          options:0
                                         progress:^(NSInteger receivedSize, NSInteger expectedSize) {
                                         }
                                        completed:^(UIImage * image, NSError * error, SDImageCacheType cacheType, BOOL finished, NSURL * imageURL) {
                                            if (image) {
                                                dispatch_async (dispatch_get_main_queue (), ^{
                                                                    [self setMenuButtonImage:image
                                                                                   forButton:btn
                                                                                    withMenu:left_menu];             //
                                                                });
                                            }
                                        }];
                }
            } else {
                [btn setBackgroundImage:[UIImage imageNamed:@"more"] forState:UIControlStateNormal];
            }

            [btn addTarget:self action:@selector(leftMenu) forControlEvents:UIControlEventTouchUpInside];
            UIView * view = [[UIView alloc] initWithFrame:btn.frame];
            [view addSubview:btn];
            leftBarButton = [[BBBadgeBarButtonItem alloc] initWithCustomUIButton:(UIButton *)view];
        }

        [self setupMenuBadge:leftBarButton forData:left_menu];
    }

    BBBadgeBarButtonItem * rightBarButton;

    if (!right_menu || [right_menu count] == 0) {
        rightBarButton = nil;
    } else {
        if (right_menu[@"text"]) {
            NSString * right_menu_text = [right_menu[@"text"] description];
            UIButton * button = [[UIButton alloc] init];
            [button setTitle:right_menu_text forState:UIControlStateNormal];
            [button setTitle:right_menu_text forState:UIControlStateFocused];
            NSDictionary * style = right_menu[@"style"];

            if (style && style[@"color"]) {
                UIColor * c = [JasonHelper colorwithHexString:style[@"color"] alpha:1.0];
                [button setTitleColor:c forState:UIControlStateNormal];
            } else {
                [button setTitleColor:color forState:UIControlStateNormal];
            }

            CGFloat size = 14.0;
            NSString * font = @"HelveticaNeue";

            if (style[@"size"]) {
                size = [style[@"size"] floatValue];
            }

            if (style[@"font"]) {
                font = style[@"font"];
            }

            button.titleLabel.font = [UIFont fontWithName:font size:size];
            [button sizeToFit];
            [button addTarget:self action:@selector(rightMenu) forControlEvents:UIControlEventTouchUpInside];
            rightBarButton = [[BBBadgeBarButtonItem alloc] initWithCustomUIButton:button];
        } else {
            UIButton * btn =  [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake (0, 0, 25, 25);

            if (right_menu[@"image"]) {
                NSString * image_src = right_menu[@"image"];

                if ([image_src containsString:@"file://"]) {
                    UIImage * localImage = [UIImage imageNamed:[image_src substringFromIndex:7]];
                    [self setMenuButtonImage:localImage forButton:btn withMenu:right_menu];
                } else {
                    SDWebImageManager * manager = [SDWebImageManager sharedManager];
                    [manager downloadImageWithURL:[NSURL URLWithString:image_src]
                                          options:0
                                         progress:^(NSInteger receivedSize, NSInteger expectedSize) {
                                         }
                                        completed:^(UIImage * image, NSError * error, SDImageCacheType cacheType, BOOL finished, NSURL * imageURL) {
                                            if (image) {
                                                dispatch_async (dispatch_get_main_queue (), ^{
                                                                    [self setMenuButtonImage:image
                                                                                   forButton:btn
                                                                                    withMenu:right_menu];
                                                                });
                                            }
                                        }];
                }
            } else {
                [btn setBackgroundImage:[UIImage imageNamed:@"more"] forState:UIControlStateNormal];
            }

            [btn addTarget:self action:@selector(rightMenu) forControlEvents:UIControlEventTouchUpInside];
            UIView * view = [[UIView alloc] initWithFrame:btn.frame];
            [view addSubview:btn];
            rightBarButton = [[BBBadgeBarButtonItem alloc] initWithCustomUIButton:(UIButton *)view];
        }

        [self setupMenuBadge:rightBarButton forData:right_menu];
    }

    if (!v.menu) {
        v.menu = [[NSMutableDictionary alloc] init];
    }

    [v.menu setValue:left_menu forKey:@"left"];
    [v.menu setValue:right_menu forKey:@"right"];

    v.navigationItem.rightBarButtonItem = rightBarButton;
    v.navigationItem.leftBarButtonItem = leftBarButton;

    if (nav[@"title"]) {
        if (![[nav[@"title"] description] containsString:@"{{"] && ![[nav[@"title"] description] containsString:@"}}"]) {
            if ([nav[@"title"] isKindOfClass:[NSDictionary class]]) {
                // Advanced title
                NSDictionary * titleDict = nav[@"title"];

                if (titleDict[@"type"]) {
                    if ([titleDict[@"type"] isEqualToString:@"image"]) {
                        NSString * url = titleDict[@"url"];
                        NSDictionary * style = titleDict[@"style"];

                        if (url) {
                            if ([url containsString:@"file://"]) {
                                UIImage * localImage = [UIImage imageNamed:[url substringFromIndex:7]];
                                [self setLogoImage:localImage withStyle:style forVC:v];
                            } else {
                                SDWebImageManager * manager = [SDWebImageManager sharedManager];
                                [manager downloadImageWithURL:[NSURL URLWithString:url]
                                                      options:0
                                                     progress:^(NSInteger receivedSize, NSInteger expectedSize) {
                                                     }
                                                    completed:^(UIImage * image, NSError * error, SDImageCacheType cacheType, BOOL finished, NSURL * imageURL) {
                                                        if (image) {
                                                            dispatch_async (dispatch_get_main_queue (), ^{
                                                                                [self setLogoImage:image
                                                                                         withStyle:style
                                                                                             forVC:v];
                                                                            });
                                                        }
                                                    }];
                            }
                        }
                    } else if ([titleDict[@"type"] isEqualToString:@"label"]) {
                        UILabel * tLabel = [[UILabel alloc] init];
                        tLabel.text = [titleDict[@"text"] description];
                        NSString * font = @"HelveticaNeue";
                        CGFloat size = 20;
                        CGFloat x = 0;
                        CGFloat y = 0;
                        [tLabel sizeToFit];

                        if (titleDict[@"style"]) {
                            if (titleDict[@"style"][@"size"]) {
                                size = [titleDict[@"style"][@"size"] floatValue];
                            }

                            if (titleDict[@"style"][@"font"]) {
                                font = titleDict[@"style"][@"font"];
                            }

                            if (titleDict[@"style"][@"left"]) {
                                x = [((NSString *)titleDict[@"style"][@"left"]) floatValue];
                            }

                            if (titleDict[@"style"][@"top"]) {
                                y = [((NSString *)titleDict[@"style"][@"top"]) floatValue];
                            }

                            if (titleDict[@"style"][@"color"]) {
                                tLabel.textColor = [JasonHelper colorwithHexString:titleDict[@"style"][@"color"] alpha:1.0];
                            }

                            tLabel.font = [UIFont fontWithName:font size:size];

                            if (titleDict[@"style"][@"align"]) {
                                if ([titleDict[@"style"][@"align"] isEqualToString:@"left"]) {
                                    UIView * titleView = [[UIView alloc] initWithFrame:tLabel.frame];
                                    [titleView addSubview:tLabel];
                                    v.navigationItem.titleView = titleView;

                                    tLabel.frame = CGRectMake (x, y, v.navigationController.navigationBar.frame.size.width, tLabel.frame.size.height);
                                    [v.navigationItem.titleView setFrame:CGRectMake (0, 0, v.navigationController.navigationBar.frame.size.width, v.navigationItem.titleView.frame.size.height)];
                                    tLabel.textAlignment = NSTextAlignmentLeft;
                                } else {
                                    [self setCenterLogoLabel:tLabel atY:y forVC:v];
                                }
                            } else {
                                [self setCenterLogoLabel:tLabel atY:y forVC:v];
                            }
                        } else {
                            [self setCenterLogoLabel:tLabel atY:y forVC:v];
                        }
                    }
                }
            } else {
                v.navigationItem.titleView = nil;
                v.navigationItem.title = [nav[@"title"] description];
            }
        } else {
            v.navigationItem.titleView = nil;
        }
    } else {
        v.navigationItem.titleView = nil;
    }

    navigationController.navigationBar.shadowImage = [UIImage new];
    [navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    CGFloat red, green, blue, alpha;
    [background getRed:&red green:&green blue:&blue alpha:&alpha];

    if (alpha < 1.0) {
        DTLogDebug (@"Setting StatusBar With Color %@", [JasonHelper hexStringFromColor:background]);
        navigationController.navigationBar.translucent = YES;
        [JasonHelper setStatusBarBackgroundColor:background];
    } else {
        DTLogDebug (@"Setting StatusBar with Clear Color");
        navigationController.navigationBar.translucent = NO;
        [JasonHelper setStatusBarBackgroundColor:[UIColor clearColor]];
    }

    navigationController.navigationBar.backgroundColor = background;
    navigationController.navigationBar.barTintColor = background;
    navigationController.navigationBar.tintColor = color;
    navigationController.navigationBarHidden = YES;
    navigationController.navigationBarHidden = NO;
}

- (void)setCenterLogoLabel:(UILabel *)tLabel atY:(CGFloat)y forVC:(JasonViewController *)v {
    UIView * view = [[UIView alloc] initWithFrame:tLabel.frame];

    [view addSubview:tLabel];
    v.navigationItem.titleView = view;
    tLabel.frame = CGRectMake (0, y, tLabel.frame.size.width, tLabel.frame.size.height);
    [tLabel sizeToFit];
    view.frame = CGRectMake (0, 0, tLabel.frame.size.width, tLabel.frame.size.height + y);
}

- (void)setLogoImage:(UIImage *)image withStyle:(NSDictionary *)style forVC:(JasonViewController *)v {
    CGFloat width = 0;
    CGFloat height = 0;
    CGFloat x = 0;
    CGFloat y = 0;

    if (style && style[@"width"]) {
        width = [((NSString *)style[@"width"]) floatValue];
    }

    if (style && style[@"height"]) {
        height = [((NSString *)style[@"height"]) floatValue];
    }

    if (style && style[@"left"]) {
        x = [((NSString *)style[@"left"]) floatValue];
    }

    if (style && style[@"top"]) {
        y = [((NSString *)style[@"top"]) floatValue];
    }

    if (width == 0) {
        width = image.size.width;
    }

    if (height == 0) {
        height = image.size.height;
    }

    CGRect frame = CGRectMake (x, y, width, height);

    UIView * logoView = [[UIView alloc] initWithFrame:frame];
    UIImageView * logoImageView = [[UIImageView alloc] initWithImage:image];

    logoImageView.frame = frame;

    [logoView addSubview:logoImageView];
    v.navigationItem.titleView = logoView;

    if (style[@"align"]) {
        if ([style[@"align"] isEqualToString:@"left"]) {
            [v.navigationItem.titleView setFrame:CGRectMake (0, 0, v.navigationController.navigationBar.frame.size.width, v.navigationItem.titleView.frame.size.height)];
        }
    }
}

- (UIButton *)setMenuButtonImage:(UIImage *)image forButton:(UIButton *)button withMenu:(NSDictionary *)menu {
    NSDictionary * style = menu[@"style"];

    if (style[@"color"]) {
        UIColor * newColor = [JasonHelper colorwithHexString:style[@"color"] alpha:1.0];
        UIImage * newImage = [JasonHelper colorize:image into:newColor];
        [button setBackgroundImage:newImage forState:UIControlStateNormal];
    } else {
        [button setBackgroundImage:image forState:UIControlStateNormal];
    }

    return button;
}

- (void)setupMenuBadge:(BBBadgeBarButtonItem *)barButton forData:(NSDictionary *)badge_menu {
    if (badge_menu[@"badge"]) {
        NSDictionary * badge = badge_menu[@"badge"];
        NSDictionary * style = badge[@"style"];

        if (style) {
            if (style[@"background"]) {
                barButton.badgeBGColor = [JasonHelper colorwithHexString:style[@"background"] alpha:1.0];
            }

            if (style[@"color"]) {
                barButton.badgeTextColor = [JasonHelper colorwithHexString:style[@"color"] alpha:1.0];
            }

            if (style[@"top"]) {
                barButton.badgeOriginY = [style[@"top"] floatValue];
            }

            if (style[@"left"]) {
                barButton.badgeOriginX = [style[@"left"] floatValue];
            }
        }

        if (badge[@"text"] && ![[badge[@"text"] description] isEqualToString:@""]) {
            barButton.badgeValue = [badge[@"text"] description];
        } else {
            barButton.badgeValue = @" ";
        }
    } else {
        barButton.badgeValue = @"";
    }
}

- (void)leftMenu {
    NSDictionary * action = [[VC.menu valueForKey:@"left"] valueForKey:@"action"];
    NSDictionary * href = [[VC.menu valueForKey:@"left"] valueForKey:@"href"];
    JasonMemory * memory = [JasonMemory client];

    if (action) {
        [memory set_stack:action];
        [self exec];
    } else if (href) {
        [self go:href];
    }
}

- (void)rightMenu {
    NSDictionary * action = [[VC.menu valueForKey:@"right"] valueForKey:@"action"];
    NSDictionary * href = [[VC.menu valueForKey:@"right"] valueForKey:@"href"];

    // Set state as the return value
    // Will be processed in the caller viewcontroller's reload
    JasonMemory * memory = [JasonMemory client];

    if (action) {
        [memory set_stack:action];
        [self exec];
    } else if (href) {
        [self go:href];
    }
}

# pragma mark - View rendering (tab)
- (void)setupTabBar:(NSDictionary *)t {
    [self setupTabBar:t forVC:VC];
}

- (void)setupTabBar:(NSDictionary *)t forVC:(JasonViewController *)v {
    dispatch_async (dispatch_get_main_queue (), ^{
        if (v.isModal) {
            // If the current view is modal, it's an entirely new view
            // so don't need to worry about how tabs should show up.
            // just skip the exception handling routine below.
        } else {
            // handling normal transition (including replace)
            // If the tabs are empty AND the view hasn't been rendered yet, then wait until it finishes rendering

            if (!t && !v.rendered) {
                if (self->previous_footer && self->previous_footer[@"tabs"]) {
                    // don't touch yet until the view finalizes
                } else {
                    self->tabController.tabBar.hidden = YES;
                }

                return;
            }
        }

        if (self->previous_footer && self->previous_footer[@"tabs"]) {
            // if previous footer tab was not null, we diff the tabs to determine whether to re-render
            if (v.old_footer && v.old_footer[@"tabs"] && [[v.old_footer[@"tabs"] description] isEqualToString:[t description]]) {
                return;
            }
        } else {
            // if previous footer tab was null, we need to construct the tab again
        }

        if (!v.old_footer) {
            v.old_footer = [[NSMutableDictionary alloc] init];
        }

        v.old_footer[@"tabs"] = t;

        if (!self->previous_footer) {
            self->previous_footer = [[NSMutableDictionary alloc] init];
        }

        self->previous_footer[@"tabs"] = t;

        if (!t || [t isKindOfClass:[NSNull class]]) {
            self->tabController.tabBar.hidden = YES;
            self->tabController.viewControllers = @[self->navigationController]; // remove all tab bar items if there's no "items"
            return;
        } else {
            self->tabController.tabBar.hidden = NO;
        }

        NSArray * tabs = t[@"items"];
        NSDictionary * style = t[@"style"];

        if (style) {
            if (style[@"color"]) {
                UIColor * c = [JasonHelper colorwithHexString:style[@"color"] alpha:1.0];
                [self->tabController.tabBar setTintColor:c];
                [[UITabBarItem appearance] setTitleTextAttributes:@{ NSForegroundColorAttributeName: c }
                                                         forState:UIControlStateSelected];
            }

            if (style[@"color:disabled"]) {
                UIColor * c = [JasonHelper colorwithHexString:style[@"color:disabled"] alpha:1.0];
                [[UIView appearanceWhenContainedInInstancesOfClasses:@[[UITabBar class]]] setTintColor:c];
                [[UITabBarItem appearance] setTitleTextAttributes:@{ NSForegroundColorAttributeName: c }
                                                         forState:UIControlStateNormal];
            }

            if (style[@"background"]) {
                [self->tabController.tabBar setClipsToBounds:YES];
                self->tabController.tabBar.shadowImage = [[UIImage alloc] init];
                self->tabController.tabBar.translucent = NO;
                self->tabController.tabBar.backgroundColor = [JasonHelper colorwithHexString:style[@"background"] alpha:1.0];
                [self->tabController.tabBar setBarTintColor:[JasonHelper colorwithHexString:style[@"background"] alpha:1.0]];
            }

            [[UITabBar appearance] setTranslucent:NO];
            [[UITabBar appearance] setBarStyle:UIBarStyleBlack];
        }

        if (tabs && tabs.count > 1) {
            NSUInteger maxTabCount = tabs.count;

            if (maxTabCount > 5) {
                maxTabCount = 5;
            }

            BOOL firstTime;
            BOOL tabFound = NO; // at least one tab item with the same url as the current VC should exist.
            NSMutableArray * tabs_array;

            // if not yet initialized, tabController.tabs.count will be 1, since this is the only view
            // that was initialized with
            // In this case, initialize all tabs
            // Start from index 1 because the first one should already be instantiated via modal href
            if (self->tabController.viewControllers.count != maxTabCount) {
                firstTime = YES;
                tabs_array = [[NSMutableArray alloc] init];
            } else {
                firstTime = NO;
            }

            // Determine the current navigation's index within the tab bar by looking at the main URL.
            // Initially set to the navigationController's position within the tab index, but this is not enough
            // because when we transition from view A with 5 tabs to view B with no tab, Jasonette gets rid of all the navigation controllers
            // so when we come back from view B, the tab bar that contains view A will only have one item, and it will say the index is 0, which is incorrect.
            // To avoid this situation, we need to be more precise and decide on the index based on the view's URL instead.
            NSUInteger indexOfTab = [self->tabController.viewControllers indexOfObject:self->navigationController];
            self->tabNeedsRefresh = YES;

            for (int i = 0; i < maxTabCount; i++) {
                NSDictionary * tab = tabs[i];

                if (tab[@"url"] && [self->VC.url isEqualToString:tab[@"url"]]) {
                    indexOfTab = i;
                    self->tabNeedsRefresh = NO;
                } else if (tab[@"href"] && tab[@"href"][@"url"] && [self->VC.url isEqualToString:tab[@"href"][@"url"]]) {
                    indexOfTab = i;
                    self->tabNeedsRefresh = NO;
                }
            }

            for (int i = 0; i < maxTabCount; i++) {
                NSDictionary * tab = tabs[i];
                NSString * url;
                NSDictionary * options = @{};
                BOOL loading = NO;
                NSDictionary * preload;

                if (tab[@"href"]) {
                    url = tab[@"href"][@"url"];
                    options = tab[@"href"][@"options"];

                    if (tab[@"href"][@"preload"]) {
                        preload = tab[@"href"][@"preload"];
                    } else if (tab[@"href"][@"loading"]) {
                        loading = YES;
                    }
                } else {
                    url = tab[@"url"];

                    if (tab[@"preload"]) {
                        preload = tab[@"preload"];
                    }
                }

                if (firstTime) {
                    // First time loading
                    if (i == indexOfTab) {
                        // for the current tab, simply add the navigationcontrolle to the tabs array
                        // no need to create a new VC, etc. because it's already been instantiated
                        tabFound = YES;
                        // if the tab URL is same as the currently visible VC's url
                        self->VC.tabNeedsRefresh = YES;
                        [tabs_array addObject:self->navigationController];
                    } else {
                        // for all other tabs, create a new VC and instantiate them, and add them to the tabs array
                        JasonViewController * vc = [[JasonViewController alloc] init];
                        vc.url = url;

                        if (self->tabNeedsRefresh) {
                            vc.tabNeedsRefresh = self->tabNeedsRefresh;
                        }

                        vc.options = [self filloutTemplate:options withData:[self variables]];
                        vc.loading = loading;
                        vc.preload = preload;
                        UINavigationController * nav = [[UINavigationController alloc] initWithRootViewController:vc];
                        [tabs_array addObject:nav];
                    }
                } else {
                    // If it's not the first time (the tab bars are already visible)
                    // check the URLs and update if changed.
                    if ([v.url isEqualToString:url]) {
                        // Do nothing
                        v.tabNeedsRefresh = YES;
                        tabFound = YES;
                    } else {
                        UINavigationController * nav = self->tabController.viewControllers[i];
                        JasonViewController * vc = [[nav viewControllers] firstObject];

                        vc.url = url;

                        if (self->tabNeedsRefresh) {
                            vc.tabNeedsRefresh = self->tabNeedsRefresh;
                        }

                        vc.options = [self filloutTemplate:options withData:[self variables]];
                        vc.loading = loading;
                        vc.preload = preload;
                    }
                }
            }

            if (firstTime) {
                self->tabController.viewControllers = tabs_array;
            }

            for (int i = 0; i < maxTabCount; i++) {
                NSDictionary * tab = tabs[i];
                [self setTabBarItem:[self->tabController.tabBar.items objectAtIndex:i] withTab:tab];
            }

            self->tabController.tabBar.hidden = NO;
        } else {
            self->tabController.tabBar.hidden = YES;
        }
    });
}

- (BOOL)      tabBarController:(UITabBarController *)theTabBarController
    shouldSelectViewController:(UIViewController *)viewController
{
    NSUInteger indexOfTab = [theTabBarController.viewControllers
                             indexOfObject:viewController];

    DTLogDebug (@"Tab Bar Touched At Index %ld", indexOfTab);

    // If moving away to a different tab bar, stop all actions currently running
    if (indexOfTab != theTabBarController.selectedIndex) {
        DTLogDebug (@"Moving Away, Stopping all Actions");
        [JasonMemory client].executing = NO;
    }

    BOOL footerContainTabs = (VC.rendered &&
                              VC.rendered[@"footer"] &&
                              VC.rendered[@"footer"][@"tabs"] &&
                              VC.rendered[@"footer"][@"tabs"][@"items"]
                              );

    if (footerContainTabs) {
        DTLogDebug (@"Footer Contains Tabs");
        NSArray * tabs = VC.rendered[@"footer"][@"tabs"][@"items"];
        NSDictionary * selected_tab = tabs[indexOfTab];

        BOOL containsHref = (selected_tab &&
                             (selected_tab[@"href"] ||
                              selected_tab[@"href"][@"url"] ||
                              selected_tab[@"url"])
                             );

        if (containsHref) {
            NSString * href = @"";

            if (selected_tab[@"href"]) {
                href = selected_tab[@"href"];

                if (selected_tab[@"href"][@"url"]) {
                    href = selected_tab[@"href"][@"url"];
                }
            } else if (selected_tab[@"url"]) {
                href = selected_tab[@"url"];
            }

            DTLogDebug (@"Tab %ld contains href %@", indexOfTab, href);

#pragma message "TabBar Refresh"

            if (self->VC.tabNeedsRefresh) {
                DTLogDebug (@"Tab %ld Needs Refresh", indexOfTab);
                [((UINavigationController *)viewController) popToRootViewControllerAnimated:NO];
                self->VC = ((UINavigationController *)viewController).viewControllers.lastObject;
                self->VC.url = href;
                [self->VC reload:nil final:NO];
                [[Jason client] call:@{ @"type": @"$render" }];
                return YES;
                /* This code contains the logic to refresh.
                 * the problem is that refreshing more than one time
                 * causes the screen to go blank. The solution was to call the $reload action.
                 * TODO: Evaluate if in the future this code will be used.
                 */
//                [((UINavigationController *) viewController) popToRootViewControllerAnimated:NO];
//                VC = ((UINavigationController *) viewController).viewControllers.lastObject;
//                VC.url = href;
//                VC.rendered = nil;
//                [self setupHeader:nil];
//                [VC reload: VC.rendered final:NO];
//                VC.contentLoaded = NO;
//                VC.tabNeedsRefresh = NO;
//                return YES;
            }

            NSString * transition = selected_tab[@"href"][@"transition"];
            NSString * view = selected_tab[@"href"][@"view"];

            if (transition) {
                if ([transition isEqualToString:@"modal"]) {
                    DTLogDebug (@"Loading with transition %@", transition);
                    [self go:[self
                              filloutTemplate:href
                                     withData:[self variables]]];
                    return NO;
                }
            }

            if (view) {
                if ([view isEqualToString:@"web"] || [view isEqualToString:@"app"]) {
                    DTLogDebug (@"Loading using %@ view", view);
                    [self go:[self
                              filloutTemplate:href
                                     withData:[self variables]]];
                    return NO;
                }
            }
        } else if (selected_tab[@"action"]) {
            [self call:selected_tab[@"action"]];
            return NO;
        } else {
            DTLogDebug (@"Tab %ld dows not contains href or url property %@", indexOfTab, selected_tab);
            return NO;
        }

        return YES;
    }

    DTLogDebug (@"Footer does not contain Tabs");
    return YES;
}

- (void)tabBarController:(UITabBarController *)theTabBarController didSelectViewController:(UIViewController *)viewController {
    navigationController = (UINavigationController *)viewController;
    VC = navigationController.viewControllers.lastObject;
}

- (void)setTabBarItem:(UITabBarItem *)item withTab:(NSDictionary *)tab {
    NSString * image = tab[@"image"];

    SDWebImageManager * manager = [SDWebImageManager sharedManager];

    if (tab[@"text"]) {
        [item setTitle:[tab[@"text"] description]];
    } else {
        [item setTitle:@""];
    }

    if (image) {
        if (tab[@"text"]) {
            [item setImageInsets:UIEdgeInsetsMake (0, 0, 0, 0)];
            [item setTitlePositionAdjustment:UIOffsetMake (0.0, -2.0)];
        } else {
            [item setImageInsets:UIEdgeInsetsMake (7.5, 0, -7.5, 0)];
        }

        if ([image containsString:@"file://"]) {
            UIImage * i = [UIImage imageNamed:[image substringFromIndex:7]];
            [self setTabImage:i withTab:tab andItem:item];
        } else {
            [manager downloadImageWithURL:[NSURL URLWithString:image]
                                  options:0
                                 progress:^(NSInteger receivedSize, NSInteger expectedSize) {
                                 }
                                completed:^(UIImage * i, NSError * error, SDImageCacheType cacheType, BOOL finished, NSURL * imageURL) {
                                    if (i) {
                                        [self setTabImage:i
                                                  withTab:tab
                                                  andItem:item];
                                    }
                                }];
        }
    } else {
        [item setTitlePositionAdjustment:UIOffsetMake (0.0, -18.0)];
    }

    if (tab[@"badge"] && ![[tab[@"badge"] description] isEqualToString:@""]) {
        [item setBadgeValue:[tab[@"badge"] description]];
    }
}

- (void)setTabImage:(UIImage *)image withTab:(NSDictionary *)tab andItem:(UITabBarItem *)item {
    CGFloat width = 0;
    CGFloat height = 0;

    if (tab[@"style"] && tab[@"style"][@"width"]) {
        width = [tab[@"style"][@"width"] floatValue];
    }

    if (tab[@"style"] && tab[@"style"][@"height"]) {
        height = [tab[@"style"][@"height"] floatValue];
    }

    if (width == 0 && height != 0) {
        width = height;
    } else if (width != 0 && height == 0) {
        height = width;
    } else if (width == 0 && height == 0) {
        width = 30;
        height = 30;
    }

    UIImage * newImage = [JasonHelper scaleImage:image ToSize:CGSizeMake (width, height)];

    dispatch_async (dispatch_get_main_queue (), ^{
        [item setImage:newImage];
    });
}

# pragma mark - View Event Handlers

/*************************************************************
*
## Event Handlers Rule ver2.
##
## 1. When there's only $show handler
## - $show: Handles both initial load and subsequent show events
##
## 2. When there's only $load handler
## - $load: Handles Only the initial load event
##
## 3. When there are both $show and $load handlers
## - $load : handle initial load only
## - $show : handle subsequent show events only
##
##
## Summary
##
## $load:
## - triggered when view loads for the first time.
## $show:
## - triggered at load time + subsequent show events (IF $load handler doesn't exist)
## - NOT triggered at load time BUT ONLY at subsequent show events (IF $load handler exists)
##
*************************************************************/

- (void)onShow
{
    NSDictionary * events = [self->VC valueForKey:@"events"];

    if (events) {
        if (events[@"$show"]) {
            dispatch_async (dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                // Temporary solution to make sure onShow doesn't interrupt rendering.
                // Will need to put some time into it to figure out a more
                // fundamental solution.
                // Similar pattern to using setTimeout(function(){ ... }, 0)
                // in javascript to schedule a task one clock tick later
                dispatch_async (dispatch_get_main_queue (), ^{
                    NSDictionary * variables = [self variables];
                    DTLogInfo (@"Calling $show event");
                    DTLogDebug (@"%@", variables);
                    [self call:events[@"$show"] with:variables];
                });
            });
        }
    }
}

- (void)onLoad:(Boolean)online
{
    [JasonMemory client].executing = NO;
    NSDictionary * events = [self->VC valueForKey:@"events"];

    if (events && events[@"$load"]) {
        if (!self->VC.contentLoaded) {
            DTLogInfo (@"Calling $load event");
            NSDictionary * variables = [self variables];
            DTLogDebug (@"%@", variables);
            [self call:events[@"$load"] with:variables];
        }
    } else {
        [self onShow];
    }

    if (online) {
        // if online is YES, it means the content is being loaded from remote, since the remote content has finished loading, set contentLoaded to YES
        // if it's NO, it means it's an offline content, so the real online content is yet to come, so shouldn't set contentLoaded to YES
        DTLogInfo (@"Content Loading From Online Remote");
        VC.contentLoaded = YES;
    }
}

- (void)onBackground
{
    isForeground = NO;
    NSDictionary * events = [self->VC valueForKey:@"events"];

    if (events) {
        if (events[@"$background"]) {
            DTLogInfo (@"Calling $background event");
            [self call:events[@"$background"]];
        }
    }
}

- (void)onForeground
{
    // Clear the app icon badge
    DTLogInfo (@"Clearing Icon Badge");
    [UIApplication sharedApplication].applicationIconBadgeNumber = 0;

    // Don't trigger if the view has already come foreground once (because this can be triggered by things like push notification / geolocation alerts)
    if (!isForeground) {
        NSDictionary * events = [self->VC valueForKey:@"events"];

        if (events) {
            if (events[@"$foreground"]) {
                DTLogInfo (@"Calling $foreground event");
                [self call:events[@"$foreground"]];
            }
        }
    }

    isForeground = YES;
}

#pragma mark Orientation Change
- (void)onOrientationChange:(NSNotification *)notification {
    UIDevice * device = notification.object;

    if (!device) {
        DTLogWarning (@"No device");
        return;
    }

    DTLogDebug (@"Changed Orientation to %ld", device.orientation);

    NSDictionary * events = [self->VC valueForKey:@"events"];

    if (events) {
        if (events[@"$orientation.changed"]) {
            CGRect frame = [UIScreen mainScreen].bounds;

            NSDictionary * params = @{
                @"$jason": @{
                    @"id": @(device.orientation),
                    @"portrait": @(UIDeviceOrientationIsPortrait (device.orientation)),
                    @"size": @{
                        @"width": @(frame.size.width),
                        @"height": @(frame.size.height)
                    }
                }
            };

            DTLogInfo (@"Calling $orientation.changed event %@", params);
            [self call:events[@"$orientation.changed"] with:params];
        }
    }
}

# pragma mark - View Linking
- (void)go:(NSDictionary *)href
{
    DTLogDebug (@"Go to href %@", href);

    // Href should be a dictionary
    if (![href respondsToSelector:@selector(objectForKey:)]) {
        DTLogDebug (@"href is not a dictionary %@", href);
        return;
    }

    /*******************************
    *
    * Linking View to another View
    *
    *******************************/
    dispatch_async (dispatch_get_main_queue (), ^{
        // Dismiss searchbar before transitioning.
        if (self->VC.searchController) {
            if (self->VC.searchController.isActive) {
                [self->VC.searchController setActive:NO];
            }
        }

        NSString * view = href[@"view"];
        NSString * transition = href[@"transition"];
        NSString * fresh = href[@"fresh"];
        JasonMemory * memory = [JasonMemory client];
        memory.executing = NO;
        self->queue = [@[] mutableCopy];

        if ([transition isEqualToString:@"root"]) {
            [self start:nil];
            return;
        }

        if ([view.lowercaseString isEqualToString:@"web"]) {
            /***************************************
            *
            * WebView using SFSafariViewController
            *
            ***************************************/
            NSString * encoded_url = [JasonHelper linkify:href[@"url"]];
            NSURL * URL = [NSURL URLWithString:encoded_url];


            DTLogDebug (@"Opening WebView with URL %@", encoded_url);

            [self unlock];
            SFSafariViewController * vc;

            /*
             * If reader mode is passed as an option then use it on the safari controller
             */
            if (href[@"options"] && (href[@"options"][@"reader"] ||
                                     href[@"options"][@"reader_mode"])) {
                DTLogDebug (@"Reader Mode Activated");
                vc = [[SFSafariViewController alloc]
                      initWithURL:URL
                                             entersReaderIfAvailable:YES];
            } else {
                vc = [[SFSafariViewController alloc] initWithURL:URL];
            }

            if ([transition isEqualToString:@"modal"]) {
                DTLogDebug (@"Presenting as modal transition");
                UINavigationController * newNav = [[UINavigationController alloc]initWithRootViewController:vc];
                [newNav setNavigationBarHidden:YES animated:NO];
                [self->navigationController presentViewController:newNav animated:YES completion:^{ }];
            } else {
                DTLogDebug (@"Presenting as push transition");
                [self->navigationController presentViewController:vc animated:YES completion:^{ }];
            }
        } else if ([view.lowercaseString isEqualToString:@"app"] || [view.lowercaseString isEqualToString:@"external"]) {
            /****************************************************************************
            *
            * Open external URL scheme such as "sms:", "mailto:", "twitter://", etc.
            *
            ****************************************************************************/
            NSString * url = href[@"url"];

#pragma message "$href action"

            DTLogDebug (@"Opening External URL %@", url);

            if (memory._register && memory._register.count > 0) {
                NSDictionary * parsed_href = [JasonHelper parse:[JasonMemory client]._register with:href];
                url = parsed_href[@"url"];
            }

            if (url) {
                // See https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/Introduction/Introduction.html#//apple_ref/doc/uid/TP40007899
                BOOL systemSchemes = ([url hasPrefix:@"tel:"] ||
                                      [url hasPrefix:@"sms:"] ||
                                      [url hasPrefix:@"mailto:"] ||
                                      [url hasPrefix:@"facetime:"] ||
                                      [url hasPrefix:@"facetime-audio:"]);

                if (systemSchemes) {
                    #if TARGET_IPHONE_SIMULATOR
                    DTLogWarning (@"Calling tel:, sms:, mailto:, facetime:, facetime-audio: urls in simulator do not work. Test them in a device.");
                    [self call:@{ @"type": @"$util.alert",
                                  @"options": @{
                                      @"description": @"This action should be tested in a real device"
                    } }];
                    #endif
                }

                // Secure the url as per apple guidelines
                // in https://developer.apple.com/documentation/uikit/inter-process_communication/allowing_apps_and_websites_to_link_to_your_content/defining_a_custom_url_scheme_for_your_app

                NSMutableCharacterSet * chars = [[NSCharacterSet URLHostAllowedCharacterSet] mutableCopy];
                [chars formUnionWithCharacterSet:[NSCharacterSet URLPathAllowedCharacterSet]];
                [chars formUnionWithCharacterSet:[NSCharacterSet URLQueryAllowedCharacterSet]];
                [chars formUnionWithCharacterSet:[NSCharacterSet URLFragmentAllowedCharacterSet]];
                [chars formUnionWithCharacterSet:[NSCharacterSet URLUserAllowedCharacterSet]];
                [chars formUnionWithCharacterSet:[NSCharacterSet URLPasswordAllowedCharacterSet]];

                NSString * encodedUrl = [[url stringByRemovingPercentEncoding]
                                         stringByAddingPercentEncodingWithAllowedCharacters:chars];

                NSURL * destination = [NSURL URLWithString:encodedUrl];

                DTLogDebug (@"openURL: %@", encodedUrl);

                [[UIApplication sharedApplication] openURL:destination
                                                   options:@{}
                                         completionHandler:^(BOOL success) {
                                             DTLogDebug (@"Openned %@", encodedUrl);
                                         }];
            } else {
                DTLogWarning (@"Invalid Url");
            }

            [self unlock];
        } else {
            if (!view || (view && [view.lowercaseString isEqualToString:@"jason"])) {
                // Jason View
                NSString * viewClass = @"JasonViewController";

                DTLogDebug (@"Opening Jason View with Transition %@", transition);

                if ([transition isEqualToString:@"replace"]) {
                    DTLogDebug (@"Replacing the current view");
                    /****************************************************************************
                    *
                    * Replace the current view
                    *
                    ****************************************************************************/
                    [self unlock];

                    if (href) {
                        NSString * new_url;
                        NSDictionary * new_options;

                        if (href[@"url"]) {
                            new_url = [JasonHelper linkify:href[@"url"]];
                        }

                        if (href[@"options"]) {
                            new_options = [JasonHelper parse:memory._register with:href[@"options"]];
                        } else {
                            new_options = @{};
                        }

                        [self start:@{ @"url": new_url, @"loading": @YES, @"options": new_options }];
                    }
                } else if ([transition isEqualToString:@"modal"]) {
                    /****************************************************************************
                    *
                    * Modal Transition
                    *
                    ****************************************************************************/

                    Class v = [JasonNSClassFromString classFromString:viewClass];
                    JasonViewController * vc = [[v alloc] init];
                    UINavigationController * nav = [[UINavigationController alloc] initWithRootViewController:vc];
                    UITabBarController * tab = [[UITabBarController alloc] init];
                    tab.viewControllers = @[nav];

                    vc.isModal = YES;

                    if (fresh) {
                        vc.fresh = YES;
                    } else {
                        vc.fresh = NO;
                    }

                    if (href) {
                        if (href[@"url"]) {
                            NSString * url = [JasonHelper linkify:href[@"url"]];

                            if ([vc respondsToSelector:@selector(url)]) {
                                vc.url = url;
                            }
                        }

                        if (href[@"preload"]) {
                            vc.preload = href[@"preload"];
                        } else if (href[@"loading"]) {
                            vc.loading = [href[@"loading"] boolValue];
                        }

                        if ([vc respondsToSelector:@selector(options)]) {
                            vc.options = href[@"options"];
                        }

                        [self unlock];
                    }

                    UITabBarController * root = (UITabBarController *)[[[UIApplication sharedApplication] keyWindow] rootViewController];

                    while (root.presentedViewController) {
                        root = (UITabBarController *)root.presentedViewController;
                    }

                    // Hide tab bar before opening modal
                    vc.extendedLayoutIncludesOpaqueBars = YES;
                    root.tabBar.hidden = YES;

                    [root presentViewController:tab
                                       animated:YES
                                     completion:^{
                                     }];
                    CFRunLoopWakeUp (CFRunLoopGetCurrent ());
                } else {
                    /****************************************************************************
                    *
                    * [Default] Push transition
                    *
                    ****************************************************************************/
                    Class v = [JasonNSClassFromString classFromString:viewClass];
                    JasonViewController * vc = [[v alloc] init];

                    if (href) {
                        if (href[@"url"]) {
                            NSString * url = [JasonHelper linkify:href[@"url"]];
                            vc.url = url;
                        }

                        if (href[@"options"]) {
                            vc.options = [JasonHelper parse:memory._register with:href[@"options"]];
                        }

                        if (href[@"preload"]) {
                            vc.preload = href[@"preload"];
                        } else if (href[@"loading"]) {
                            vc.loading = [href[@"loading"] boolValue];
                        }

                        if (fresh) {
                            vc.fresh = YES;
                        } else {
                            vc.fresh = NO;
                        }

                        [self unlock];
                    }

                    vc.extendedLayoutIncludesOpaqueBars = YES;

                    if (self->tabController.tabBar.hidden) {
                        self->tabController.tabBar.hidden = YES;
                    } else {
                        if ([transition isEqualToString:@"fullscreen"]) {
                            vc.hidesBottomBarWhenPushed = YES;
                        } else {
                            vc.hidesBottomBarWhenPushed = NO;
                        }
                    }

                    [self->navigationController pushViewController:vc animated:YES];
                }
            } else {
                /****************************************************************************
                *
                ** Custom ViewControllers
                **
                ** 1. Opening your custom view from Jason view
                ** 1.1. Using storyboard
                ** To transition from Jasonette to Your custom view controller,
                ** Simply declare the view controller class name as:
                **
                ** [Storyboard Name].[The viewcontroller's storyboard ID]
                **
                ** [Example]
                ** if your storyboard is named "MainStoryboard.storyboard", and the viewcontroller has the id "LiveStreamView",
                **
                ** simply attach the following href to any component you desire:
                **
                ** {
                ** "type": "label",
                ** "text": "Start livestreaming",
                ** "href": {
                ** "view": "MainStoryboard.LiveStreamView"
                ** }
                ** }
                ** 1.2. Without storyboard
                ** To transition from Jasonette to Your custom view controller,
                ** Simply declare the view controller class name as "view" attribute.
                **
                ** [Example]
                ** if you have a view controller class called "LiveStreamViewController",
                ** simply attach the following href to any component you desire:
                **
                ** {
                ** "type": "label",
                ** "text": "Start livestreaming",
                ** "href": {
                ** "view": "LiveStreamViewController"
                ** }
                ** }
                **
                ** 1.3. Passing parameters
                ** To pass parameters to your custom view controller,
                **
                ** A. just add a property called "jason" to your view controller like this:
                **
                ** @property (nonatomic, strong) NSDictionary *jason
                **
                ** B. Then pass values via 'options' attribute like this:
                **
                ** {
                ** "type": "label",
                ** "text": "Make a payment",
                ** "href": {
                ** "view": "PaymentViewController",
                ** "options": {
                ** "product_id": "dnekfsl",
                ** "user_id": "3kz"
                ** }
                ** }
                ** }
                **
                ** C. Then use the jason NSDictionary from your custom view controller
                **
                ** // PaymentViewController.m
                #import "PaymentViewController.h"
                ** @implementation PaymentViewController
                ** ....
                ** - (void)viewDidLoad {
                ** [super viewDidLoad];
                ** NSString *product_id = self.jason[@"product_id"];
                ** NSString *user_id = self.jason[@"user_id"];
                **
                ** // do some customization with product_id and user_id
                ** }
                ** ....
                ** @end
                **
                ** 2. Opening Jason view from your custom viewcontrollers
                **
                ** Opening Jasonette from your viewcontrollers is same as opening any other viewcontrollers.
                **
                ** A. First, include JasonViewController.h in your viewcontroller
                **
                #import "JasonViewController.h"
                **
                ** B. To display Jasonette view with push transition:
                **
                ** JasonViewController *vc = [[JasonViewController alloc] init];
                ** vc.url = @"https://jasonbase.com/things/jYJ.json";
                ** [self.navigationViewController pushViewController:vc animated:YES];
                **
                ** C. To present Jasonette view as modal:
                **
                ** JasonViewController *vc = [[JasonViewController alloc] init];
                ** vc.url = @"https://jasonbase.com/things/jYJ.json";
                ** UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                ** [self.navigationController presentViewController:nav animated:YES completion:nil];
                **
                **
                ****************************************************************************/

                // Instantiate ViewController
                JasonViewController * vc;
                UINavigationController * nav;
                NSArray * tokens = [href[@"view"] componentsSeparatedByString:@"."];

                // 1. via "view": "[STORYBOARD_NAME].[VIEWCONTROLLER_STORYBOARD_ID]" format
                if (tokens.count == 2) {
                    NSString * storyboardName = tokens[0];
                    NSString * storyboardIdentifier = tokens[1];
                    UIStoryboard * storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
                    vc = [storyboard instantiateViewControllerWithIdentifier:storyboardIdentifier];
                    nav = vc.navigationController;
                }
                // 2. via "view": "[VIEWCONTROLLER_CLASSNAME]" format
                else {
                    Class CustomViewController = [JasonNSClassFromString classFromString:href[@"view"]];
                    vc = [[CustomViewController alloc] init];
                    nav = [[UINavigationController alloc] initWithRootViewController:vc];
                }

                // Option 1. Present as modal
                if ([transition isEqualToString:@"modal"]) {
                    if (href[@"options"]) {
                        if ([vc respondsToSelector:NSSelectorFromString (@"jason")]) {
                            [vc setValue:href[@"options"] forKey:@"jason"];
                        }
                    }

                    [self unlock];
                    [self->navigationController presentViewController:nav
                                                             animated:YES
                                                           completion:^{
                                                           }];
                    CFRunLoopWakeUp (CFRunLoopGetCurrent ());
                }
                // Option 2. Push transition
                else {
                    if (href[@"options"]) {
                        if ([vc respondsToSelector:NSSelectorFromString (@"jason")]) {
                            [vc setValue:href[@"options"] forKey:@"jason"];
                        }
                    }

                    [self unlock];
                    [self->navigationController pushViewController:vc animated:YES];
                }
            }
        }
    });
}

# pragma mark - Action invocation related

/**********************************************************************************************************************
 *
 * Generates 'options' object to be passed to the next action in the call chain by looking at the stack, register, etc.
 *
 *********************************************************************************************************************/

- (NSDictionary *)options
{
    JasonMemory * memory = [JasonMemory client];

    /*********************************************************************************************************
     *
     * Step 1.
     *
     * "IF" clause handling
     *
     * If the stack contains an array, it may mean it's an if clause
     *
     * (ex)
     *
     *   [
     *        {
     *            "{{#if result.length > 0}}": {...}
     *        },
     *        {
     *            "{{#else}}": {...}
     *        }
     *    ]
     *
     * In this case we need to fill it out once to reduce it down to the actual expression to be executed
     *
     ********************************************************************************************************/
    NSDictionary * reduced_stack;

    if ([memory._stack isKindOfClass:[NSArray class]]) {
        reduced_stack = [self filloutTemplate:memory._stack withData:memory._register];
    } else {
        reduced_stack = [memory._stack mutableCopy];
    }

    /*********************************************************************************************************
     *
     * Step 2. Now that the if conditionals are out of the way, actually fill out the result options template with register
     *
     ********************************************************************************************************/
    if (reduced_stack[@"options"]) {
        return [self filloutTemplate:reduced_stack[@"options"] withData:memory._register];
    } else {
        return nil;
    }
}

- (void)exec
{
    DTLogDebug (@"Executing Action");
    @try {
        JasonMemory * memory = [JasonMemory client];
        // need to set the 'executing' state to NO initially
        // until it actually starts executing
        memory.executing = NO;

        if (memory._stack && memory._stack.count > 0) {
            /****************************************************
            * First, handle conditional cases
            * If the stack contains an array, it must be a conditional. (#if)
            # So run it through 'options' method to generate an actual stack
            ****************************************************/
            if ([memory._stack isKindOfClass:[NSArray class]]) {
                memory._stack = [self filloutTemplate:memory._stack withData:memory._register];
            }

            NSString * trigger = memory._stack[@"trigger"];
            NSString * type = memory._stack[@"type"];

            // Type 1. Action Call by name (trigger)
            if (trigger) {
                DTLogDebug (@"Trigger Detected");
                /****************************************************************************************
                *  // "trigger" is a syntactic sugar for calling `$lambda` action
                *
                *  The syntax is as follows:
                *
                *  {
                *  "trigger": "twitter.get",
                *  "options": {
                *  "endpoint": "timeline"
                *  },
                *  "success": {
                *  "type": "$render"
                *  },
                *  "error": {
                *  "type": "$util.toast",
                *  "options": {
                *  "text": "Uh oh. Something went wrong"
                *  }
                *  }
                *  }
                *
                *  Above is a syntactic sugar for the below "$lambda" type action call:
                *
                *  $lambda action is a special purpose action that triggers another action by name and waits until it returns.
                *  This way we can define a huge size action somewhere and simply call them as a subroutine and wait for its return value.
                *  When the subroutine (the lambda action that was triggered by name) returns via `"type": "$return.success"` action,
                *  the $lambda action picks up where it left off and starts executing its "success" action with the value returned from the subroutine.
                *
                *  Notice that:
                *  1. we get rid of the "trigger" field and turn it into a regular action of `"type": "$lambda"`.
                *  2. the "trigger" value (`"twitter.get"`) gets mapped to "options.name"
                *  3. the "options" value (`{"endpoint": "timeline"}`) gets mapped to "options.options"
                *
                *
                *  {
                *  "type": "$lambda",
                *  "options": {
                *  "name": "twitter.get",
                *  "options": {
                *  "endpoint": "timeline"
                *  }
                *  },
                *  "success": {
                *  "type": "$render"
                *  },
                *  "error": {
                *  "type": "$util.toast",
                *  "options": {
                *  "text": "Uh oh. Something went wrong"
                *  }
                *  }
                *  }
                *
                *  The success / error actions get executed AFTER the triggered action has finished and returns with a return value.
                *
                ****************************************************************************************/

                // Construct a new JSON from the trigger JSON
                NSString * lambda_name = memory._stack[@"trigger"];
                NSMutableDictionary * lambda = [[NSMutableDictionary alloc] init];
                lambda[@"type"] = @"$lambda";

                if (memory._stack[@"options"]) {
                    lambda[@"options"] = @{ @"name": lambda_name, @"options": memory._stack[@"options"] };
                } else {
                    lambda[@"options"] = @{ @"name": lambda_name };
                }

                if (memory._stack[@"success"]) {
                    lambda[@"success"] = memory._stack[@"success"];
                }

                if (memory._stack[@"error"]) {
                    lambda[@"error"] = memory._stack[@"error"];
                }

                [self call:lambda with:memory._register];
            }
            // Type 2. Action Call by type (normal)
            else if (type) {
                DTLogDebug (@"Action Call by Type");
                NSArray * tokens = [type componentsSeparatedByString:@"."];

                // Jason Core actions: "METHOD" format => Within Jason.m
                if (tokens.count == 1) {
                    if (type.length > 1 && [type hasPrefix:@"$"]) {
                        NSString * actionName = [type substringFromIndex:1];
                        SEL method = NSSelectorFromString (actionName);
                        self.options = [self options];

                        // Set 'executing' to YES to prevent other actions from being accidentally executed concurrently
                        memory.executing = YES;

                        if ([self respondsToSelector:method]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            DTLogDebug (@"Performing %@", actionName);
                            [self performSelector:method];
#pragma clang diagnostic pop
                        } else {
                            DTLogDebug (@"Could Not Perform %@", actionName);
                        }
                    }
                } else if ([type hasPrefix:@"@"]) {
                    DTLogDebug (@"Plugin method detected");
                    /*
                     * Call a 'plug in method'.  We now take the full type w/o the '@‘ prefix
                     * and try to load that class.  This gives us more freedom with class names
                     * and allows for implementations in Swift -- Swift "classes" always have their
                     * module name compiled in.
                     *
                     * Examples:
                     *
                     * {
                     *    "type": "@MyActionClass.demo",
                     *    "options": {
                     *        "foo": "42"
                     *    }
                     * }
                     *
                     * Or for Swift:
                     *
                     * {
                     *    "type": "@MyActionModule.SomeClassName.demo",
                     *    "options": {
                     *        "foo": "42"
                     *    }
                     * }
                     *
                     */

                    // skip prefix to get module path
                    NSString * plugin_path = [type substringFromIndex:1];
                    DTLogDebug (@"Plugin: plugin path: %@", plugin_path);

                    // The module name is the plugin path w/o the last part
                    // e.g. "MyModule.MyClass.demo" -> "MyModule.MyClass"
                    //      "MyClass.demo" -> "MyClass"
                    NSArray * mod_tokens = [plugin_path componentsSeparatedByString:@"."];

                    if (mod_tokens.count > 1) {
                        NSString * module_name = [[mod_tokens
                                                   subarrayWithRange:NSMakeRange (0, mod_tokens.count - 1)]
                                                  componentsJoinedByString:@"."];

                        NSString * action_name = [mod_tokens lastObject];

                        DTLogDebug (@"Plugin: module name: %@", module_name);
                        DTLogDebug (@"Plugin: action name: %@", action_name);

                        Class PluginClass = [JasonNSClassFromString classFromString:module_name];

                        if (PluginClass) {
                            DTLogDebug (@"Plugin: class: %@", PluginClass);

                            // Initialize Plugin
                            module = [[PluginClass alloc] init];  // could go away if we had some sort of plug in registration

                            [[NSNotificationCenter defaultCenter]
                             postNotificationName:plugin_path
                                           object:self
                                         userInfo:@{
                                 @"vc": VC,
                                 @"plugin_path": plugin_path,
                                 @"action_name": action_name,
                                 @"options": [self options]
                            }];
                        } else {
                            DTLogDebug (@"Plugin Class '%@ doesn't exist.", module_name);
                            [[Jason client] call:@{ @"type": @"$util.banner",
                                                    @"options": @{
                                                        @"title": @"Error",
                                                        @"description":
                                                        [NSString stringWithFormat:@"Plugin class '%@' doesn't exist.", module_name]
                            } }];
                        }
                    } else {
                        // ignore error: "@ModuleName" -> missing action name
                        DTLogDebug (@"Missing Action Name");
                    }
                }
                // Module actions: "$CLASS.METHOD" format => Calls other classes
                else {
                    DTLogDebug (@"$class.method format");
                    NSString * className = tokens[0];

                    // first take a look at the json file to resolve classname
                    NSString * resourcePath = [[NSBundle mainBundle] resourcePath];
                    NSString * jrjson_filename = [NSString stringWithFormat:@"%@/%@.json", resourcePath, className];
                    NSFileManager * fileManager = [NSFileManager defaultManager];
                    NSString * resolved_classname = nil;

                    if ([fileManager fileExistsAtPath:jrjson_filename]) {
                        NSError * error;
                        NSInputStream * inputStream = [[NSInputStream alloc] initWithFileAtPath:jrjson_filename];

                        [inputStream open];
                        NSDictionary * json = [NSJSONSerialization
                                               JSONObjectWithStream:inputStream
                                                            options:kNilOptions
                                                              error:&error];
                        [inputStream close];

                        if (error) {
                            DTLogWarning (@"%@", error);
                        }

                        if (json[@"classname"]) {
                            resolved_classname = json[@"classname"];
                        }
                    } else {
                        if (className.length > 1 && [className hasPrefix:@"$"]) {
                            resolved_classname = [[className substringFromIndex:1] capitalizedString];
                            /*
                             *
                             * CLASS name Needs to follow the following convention:
                             *
                             * "Jason[CLASSNAME]Action"
                             *
                             * example: JasonMediaAction, JasonAudioAction, JasonNetworkAction, etc.
                             *
                             */

                            resolved_classname = [NSString stringWithFormat:@"Jason%@Action", resolved_classname];
                        }
                    }

                    if (resolved_classname) {
                        DTLogDebug (@"Resolved Classname %@", resolved_classname);
                        Class ActionClass = [JasonNSClassFromString classFromString:resolved_classname];

                        if (ActionClass) {
                            // This means I have implemented this already
                            NSString * methodName = tokens[1];
                            SEL method = NSSelectorFromString (methodName);

                            NSDictionary * options = [self options];

                            module = [[ActionClass alloc] init];

                            if ([module respondsToSelector:NSSelectorFromString (@"VC")]) {
                                [module setValue:VC forKey:@"VC"];
                            }

                            if ([module respondsToSelector:NSSelectorFromString (@"options")]) {
                                [module setValue:options forKey:@"options"];
                            }

                            // Set 'executing' to YES to prevent other actions from being accidentally executed concurrently
                            memory.executing = YES;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            DTLogDebug (@"Perform %@", methodName);
                            [module performSelector:method];
#pragma clang diagnostic pop
                        } else {
                            DTLogWarning (@"%@ class doesn't exist.", resolved_classname);
                            [[Jason client] call:@{ @"type": @"$util.banner",
                                                    @"options": @{
                                                        @"title": @"Error",
                                                        @"description": [NSString stringWithFormat:@"%@ class doesn't exist.", resolved_classname]
                            } }];
                        }
                    }
                }

                // If the stack doesn't include any action to take after success, just finish
                if (!memory._stack[@"success"] && !memory._stack[@"error"]) {
                    // VC.contentLoaded is NO if the action is $reload (until it returns)
                    if (VC.contentLoaded) {
                        [self finish];
                    }
                }
            } else {
                [self unlock];
            }
        } else {
            /****************************************************
            *
            * Stack empty. Time to finish!
            *
            ****************************************************/
            [self finish];
        }
    } @catch (NSException * e) {
        DTLogError (@"ERROR.. %@", e);
        DTLogError (@"JasonStack : %@", [JasonMemory client]._stack);
        DTLogError (@"Register : %@", [JasonHelper stringify:[JasonMemory client]._register]);
        [self call:@{ @"type": @"$util.banner", @"options": @{ @"title": @"Error", @"description": @"Something went wrong. Please try again" } }];
        [self finish];
    }
}

- (void)exception
{
    [[JasonMemory client] exception];
    [self exec];
}

- (void)next
{
    [[JasonMemory client] pop];
    [self exec];
}

- (void)finish
{
    DTLogDebug (@"Finish");
    [self unlock];
}

- (void)unlock
{
    DTLogDebug (@"Unlock");
    [self loading:NO];
    JasonMemory * mem = [JasonMemory client];

    if (mem && mem._stack && mem._stack[@"type"] && [mem._stack[@"type"] isEqualToString:@"$ok"]) {
        // don't touch the return value;
    } else {
        [JasonMemory client]._register = @{};
    }

    [JasonMemory client]._stack = @{};
    [JasonMemory client].locked = NO;
    [JasonMemory client].executing = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"finishRefreshing" object:nil];

    dispatch_async (dispatch_get_main_queue (), ^{
        self->VC.view.userInteractionEnabled = YES;
    });

    [[NSNotificationCenter defaultCenter] postNotificationName:@"unlock" object:nil];

    // In case oauth was in process, set it back to No
    self.oauth_in_process = NO;

    // resume the next task in the queue, now that one call chain has finished.
    if (queue.count > 0) {
        NSDictionary * a = [[queue firstObject] copy];
        [queue removeObjectAtIndex:0];
        [self call:a[@"action"] with:a[@"data"]];
    }
}

# pragma mark - Helpers, Delegates & Misc.

- (void)cache_view
{
    // Experimental: Store cache content for offline
    DTLogInfo (@"Loading View From Cache");

    if (self->VC.original && self->VC.rendered && self->VC.original[@"$jason"][@"head"][@"offline"]) {
        DTLogInfo (@"Offline Mode Activated");

        if (![[self->VC.rendered description] containsString:@"{{"] && ![[self.options description] containsString:@"}}"]) {
            dispatch_async (dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                NSString * normalized_url = [JasonHelper normalized_url:self->VC.url forOptions:self->VC.options];
                normalized_url = [normalized_url stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                NSArray * paths = NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES);
                NSString * documentsDirectory = [paths objectAtIndex:0];
                NSString * path = [documentsDirectory stringByAppendingPathComponent:normalized_url];

                NSMutableDictionary * to_store = [self->VC.original mutableCopy];

                if (to_store[@"$jason"]) {
                    to_store[@"$jason"][@"body"] = self->VC.rendered;
                }

                NSData * data = [NSKeyedArchiver archivedDataWithRootObject:to_store];
                [data writeToFile:path atomically:YES];
                return;
            });
        }
    }

    // if not offline, delete the file associated with the url
    NSString * normalized_url = [JasonHelper normalized_url:self->VC.url forOptions:self->VC.options];

    normalized_url = [normalized_url stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSArray * paths = NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES);
    NSString * documentsDirectory = [paths objectAtIndex:0];
    NSString * path = [documentsDirectory stringByAppendingPathComponent:normalized_url];
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:path];

    if (fileExists) {
        NSError * error;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    }
}

@end
