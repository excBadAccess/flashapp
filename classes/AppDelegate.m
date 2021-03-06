//
//  AppDelegate.m
//  flashapp
//
//  Created by 李 电森 on 11-12-12.
//  Copyright (c) 2011年 __MyCompanyName__. All rights reserved.

#import <CoreTelephony/CTCall.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <TencentOpenAPI/TencentOAuth.h>
#import "AppDelegate.h"
#import "DatasaveViewController.h"
#import "DatastatsScrollViewController.h"
#import "SettingViewController.h"
#import "IDCPickerViewController.h"
#import "HelpNetBadViewController.h"
#import "HelpCompressViewController.h"
#import "InstallProfileViewController.h"
#import "OpenVPNViewController.h"
#import "RegisterViewController.h"
#import "HelpViewController.h"
#import "SetupViewController.h"
#import "DBConnection.h"
#import "StatsDayDAO.h"
#import "SystemVariablesDAO.h"
#import "DeviceInfo.h"
#import "UIDevice-Reachability.h"
#import "UIDevice-software.h"
#import "TwitterClient.h"
#import "DateUtils.h"
#import "StringUtil.h"
#import "TCUtils.h"
#import "AppInfo.h"
#import "OpenUDID.h"
#import "JSON.h"
#import "HelpListViewController.h"
#import "MyNetWorkClass.h"
#import "CategoryClass.h"
#import "AppClasses.h"
#import "AppRecommedDao.h"
#import "CustomTabBarViewController.h"
#import "Flurry.h"

#ifdef DFTraffic
#import "AiDfTraffic.h"
#endif


#define APPID 482502199

@implementation AppDelegate

@synthesize window = _window;
@synthesize dbWriteLock;
@synthesize user;
@synthesize carrier;
@synthesize refreshDatasave;
@synthesize refreshDatastats;
@synthesize proxySlow;
@synthesize networkReachablity;
@synthesize adjustSMSSend;
@synthesize refreshingLock;
@synthesize rootNav;
@synthesize customTabBar;


#pragma mark - init & destroy

- (void)dealloc
{
    [_window release];
    [dbWriteLock release];
    [timerTaskLock release];
    [user release];
    [carrier release];
    [networkReachablity release];
    [refreshThread release];
    [operationQueue release];
    [locationManager release];
    [rootNav release];
    [customTabBar release];
    
    [super dealloc];
}


#pragma mark - bussiness methods

/*! @brief 更新、创建数据库。
 *
 * 程序启动后去判断版本号，根据判断的版本号去更细数据库。
 * @param versionUpgrade 判断是否是1.3版本之前 ，或者是1.9.1版本之后
 * @return nil。
 */
- (void) initDatabase:(BOOL)versionUpgrade
{
    BOOL forceCreate = NO;
    if ( versionUpgrade ) {
        forceCreate = YES;
    }
    else {
        forceCreate = [[NSUserDefaults standardUserDefaults] boolForKey:@"dropDatabase"];
    }
    self.dbWriteLock = [[[NSObject alloc] init] autorelease];
    [DBConnection createEditableCopyOfDatabaseIfNeeded:forceCreate];
    [DBConnection getDatabase];
}


- (int) execUpgradeSQL:(NSString*)newVersion oldVersion:(NSString*)oldVersion
{
    if ( [newVersion compare:oldVersion] == NSOrderedSame ) return SQLITE_OK;
    if ( [@"0" compare:oldVersion] == NSOrderedSame ) return SQLITE_OK;
    
    NSString* path = [[NSBundle mainBundle] pathForResource:@"sql" ofType:@"plist"];
    NSDictionary* dic = [NSDictionary dictionaryWithContentsOfFile:path];
    
    NSArray* versions = [[dic allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSArray* sqls;
    char* error;
    int ret;
    ret = SQLITE_OK;
    
    [DBConnection beginTransaction];
    for ( NSString* v in versions ) {
        NSLog(@"version=%@", v);
        if ( [v compare:oldVersion] == NSOrderedDescending && 
            ([v compare:newVersion] == NSOrderedAscending || [v compare:newVersion] == NSOrderedSame) ) {
            sqls = [dic objectForKey:v];
            for ( NSString* sql in sqls ) {
                NSLog(@"sql=%@", sql);
                ret = [DBConnection execute:(char*)[sql UTF8String] errmsg:&error];
                if ( ret != SQLITE_OK ) {
                    break;
                }
            }
        }
        
        if ( ret != SQLITE_OK ) break;
    }
    
    if ( ret == SQLITE_OK ) {
        [DBConnection commitTransaction];
    }
    else {
        [DBConnection rollbackTransaction];
    }
    return ret;
}


- (void) switchUser
{
    self.refreshDatasave = YES;
    self.refreshDatastats = YES;
    
    [DBConnection clearDB];
}


+ (long long) getLastAccessLogTime
{
    long long lastDayLong = 0;
    NSString* value = [SystemVariablesDAO getValue:[AppDelegate getAppDelegate].user.idcServer];
    if ( value ) lastDayLong = [value longLongValue];
    return lastDayLong;
}


- (BOOL) proxyServerSlow
{
    NSString* proxyServer = user.proxyServer;
    int proxyPort = user.proxyPort;
    
    if ( proxyPort == 0 || proxyServer.length == 0 ) return NO;
    
    long long myDuration = 0;
    long long baiduDuration = 0;
    
    for ( int i=0; i<3; i++ ) {
        //通过socket访问代理服务器，并记录时长
        long long time1 = [DateUtils millisecondTime];
        [TFConnection connectSocket:proxyServer port:proxyPort];
        long long time2 = [DateUtils millisecondTime];
        
        //如果访问代理服务器时长小于500毫秒，则认为速度正常，返回NO
        myDuration += time2 - time1;
        if ( myDuration < 500 ) return NO;
        
        //通过socket访问baidu，并记录时长
        NSString* otherServer = @"www.baidu.com";
        int otherPort = 80;
        [TFConnection connectSocket:otherServer port:otherPort];
        time1 = [DateUtils millisecondTime];
        baiduDuration += time1 - time2;
    }

    //如果访问代理服务器的时间，大于访问baidu所用时间的4倍，则认为代理服务器太慢，返回YES
    //否则认为代理服务器速度正常，返回NO
    if ( myDuration > baiduDuration * 4.0 ) {
        return YES;
    }
    else {
        return NO;
    }
}


- (void) getMemberInfo
{
    //访问getMemberInfo接口
    operationQueue = [[NSOperationQueue alloc] init];
    [operationQueue setMaxConcurrentOperationCount:1];
    NSInvocationOperation* operation = [[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(requestMemberInfo) object:nil] autorelease];
    [operationQueue addOperation:operation];
}


- (void) requestMemberInfo
{
    Reachability* reachablity = [Reachability reachabilityWithHostName:P_HOST];    
    if ( [reachablity currentReachabilityStatus] == NotReachable ) return;
    
    [TwitterClient getMemberInfoSync];
    
    UIDevice* device = [UIDevice currentDevice];
    if ( [device isJailbroken] ) {
        //对于越狱的手机，上传安装的应用信息
        [self uploadAppInfo];
    }
}


- (void) startLocationManager
{
    [locationManager startManager];
}


- (void) stopLocationManager
{
    [locationManager stopManager];
}


#pragma mark - basic tool methods

+ (AppDelegate*)getAppDelegate
{
    return (AppDelegate*)[UIApplication sharedApplication].delegate;
}


+ (Reachability*) getNetworkReachablity
{
    Reachability* reachable = [Reachability reachabilityWithHostName:P_HOST];
    return reachable;
}


+ (BOOL) networkReachable
{
    Reachability* reachablity = [Reachability reachabilityWithHostName:P_HOST];
    if ( [reachablity currentReachabilityStatus] == NotReachable ) {
        return NO;
    }
    else {
        return YES;
    }
}


+ (void) showAlert:(NSString*)message
{
	UIAlertView* alertView = [[UIAlertView alloc] initWithTitle:@"提示" 
														message:message 
													   delegate:nil 
											  cancelButtonTitle:@"确定" 
											  otherButtonTitles:nil];
	[alertView show];
	[alertView release];
}


+ (void) showAlert:(NSString*)title message:(NSString*)message
{
	UIAlertView* alertView = [[UIAlertView alloc] initWithTitle:title 
														message:message 
													   delegate:nil 
											  cancelButtonTitle:@"确定" 
											  otherButtonTitles:nil];
	[alertView show];
	[alertView release];
}


+ (void) showHelp
{
    //NSString* url = @"http://p.flashapp.cn/faq.html";
    NSString *url = [NSString stringWithFormat:@"file://%@/%@",[[NSBundle mainBundle] bundlePath],@"flashapp/faq/faq.html" ];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
}


+ (void) showUserReviews
{
    NSString *str = [NSString stringWithFormat:
                     @"itms-apps://ax.itunes.apple.com/WebObjects/MZStore.woa/wa/viewContentsUserReviews?type=Purple+Software&id=%d",
                     APPID ];  
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:str]];
}


- (UINavigationController*) currentNavigationController
{
    return (UINavigationController*) self.customTabBar.selectedViewController;
}


- (UIViewController*) currentViewController
{
    UINavigationController* nav = [self currentNavigationController];
    return [nav topViewController];
}

- (void) setNavigationBar:(UINavigationBar *)_navigationBar {
    if ([_navigationBar respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)]) {
        [_navigationBar setBackgroundImage:[[UIImage imageNamed:@"nav_bg.png"]
                                            stretchableImageWithLeftCapWidth:1 topCapHeight:0] forBarMetrics:UIBarMetricsDefault];
    }
}

#pragma mark - application delegate

- (void) showDatasaveView:(BOOL)justInstallProfile
{
    customTabBar = [[CustomTabBarViewController alloc] initWithInstallingProfile:justInstallProfile];
	self.window.rootViewController = customTabBar;
}


- (void) showSetupView
{
    SetupViewController* controller = [[SetupViewController alloc] init];
    controller.isSetup = YES;
    
    DeviceInfo* device = [DeviceInfo deviceInfoWithLocalDevice];
    float version = [device.version floatValue];
    if ( version >= 4.0 ) {
        self.window.rootViewController = controller;
        [controller release];
        //[nav release];
    }
    else {
        [self.window addSubview:controller.view];
        [controller release];
    }
}


- (void) showInstallProfileView
{
     InstallProfileViewController* profileViewController = [[InstallProfileViewController alloc] init];
    self.window.rootViewController = profileViewController;
    [profileViewController release];
}


- (void) showRegisterView
{
    RegisterViewController* controller = [[RegisterViewController alloc] init];
    UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:controller];
    self.window.rootViewController = nav;
    [controller release];
    [nav release];
}


- (void) showProfileHelp
{
    HelpViewController* controller = [[HelpViewController alloc] init];
    controller.showCloseButton = YES;
    if ( [@"vpn" isEqualToString:user.stype] ) {
        controller.page = @"vpn/YDD";
    }
    else {
        controller.page = @"profile/YDD";
    }
    UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [[self currentNavigationController] presentModalViewController:nav animated:YES];
    [controller release];
    [nav release];
}


- (void) incrDayCapacity
{
    time_t now;
    time( &now );
    NSString* day = [DateUtils stringWithDateFormat:now format:@"yyyyMMdd"];

    if ( user.day ) {
        if ( [day compare:user.day] == NSOrderedSame ) {
            if ( user.dayCapacity < QUANTITY_DAY_LIMIT ) {
                user.dayCapacity += 1;
                user.dayCapacityDelta += 1;
                user.capacity += QUANTITY_PER_OPEN;
            }
        }
        else {
            user.day = day;
            user.dayCapacity = 1;
            user.dayCapacityDelta += 1;
            user.capacity += QUANTITY_PER_OPEN;
        }
    }
    else {
        user.day = day;
        user.dayCapacity = 0;
        user.dayCapacityDelta = 0;
    }

    [UserSettings saveUserSettings:user];
}


- (void) processRemoteNotification:(NSDictionary*)userInfo
{
    NSString* type = [userInfo objectForKey:@"type"];
    if ( [@"comment" compare:type] == NSOrderedSame ) {
        [AppDelegate showUserReviews];
    }
    else if ( [@"naviurl" compare:type] == NSOrderedSame ) {
        UINavigationController* currNav = [self currentNavigationController];
        if ( currNav ) {
            NSString* url = [userInfo objectForKey:@"url"];
            NSString* title = [userInfo objectForKey:@"title"];
            if ( !title ) title = NSLocalizedString(@"AppDelegate.processRemoteNotification.title", nil);
            HelpViewController* controller = [[HelpViewController alloc] init];
            controller.showCloseButton = YES;
            controller.page = url;
            controller.title = title;
            UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:controller];
            [currNav presentModalViewController:nav animated:YES];
            [controller release];
            [nav release];
        }
    }
    else {
    }
}

/*! @brief 查询是否有新的应用程序
 *
 * 从数据库中查询出应用推荐分类是否有新的应用，有新的应用设置页面显示新应用体检。
 * @param nil
 * @return nil
 */
-(void)ifNewsApp
{
    MyNetWorkClass *myNetWork = [MyNetWorkClass getMyNetWork];
    [myNetWork startAppFenLei:^(NSDictionary *result) {
        NSMutableArray *categoryArray = [NSMutableArray arrayWithCapacity:3];
        //储存CP 下次请求数据的时候带上
        [[NSUserDefaults standardUserDefaults] setObject:[result objectForKey:@"cp"] forKey:@"catsucp"] ;
        [categoryArray addObjectsFromArray:[result objectForKey:@"catsu"]];
        NSDictionary *databaseDic = [AppRecommedDao fondAllAppRecommed];
        if ([databaseDic count] == 0) {
            [DBConnection beginTransaction];
            [AppRecommedDao insertAllAppRecommend:categoryArray];
            [DBConnection commitTransaction];
        }else{
            for (NSString *str in [databaseDic allKeys]) {
                if ([str isEqualToString:@"精品推荐"]) {
                    AppClasses *appClasses = [databaseDic objectForKey:@"精品推荐"];
                    long long new_tim = [[[categoryArray objectAtIndex:0] objectForKey:@"tim"] longLongValue];
                    long long old_tim = appClasses.appClasses_tim;
                    if (new_tim >old_tim) {
                        appClasses.appClasses_tim = new_tim;
                        [AppRecommedDao updateAppRecommend:appClasses];
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:NEWS_APP];
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JPTJ_APP];
                    }
                    NSLog(@"%@ 's NEW_TIM IS %lld , OLD_TIM IS %lld",appClasses.appClasses_name,new_tim , old_tim);
                }
                if ([str isEqualToString:@"限时免费"]) {
                    AppClasses *appClasses = [databaseDic objectForKey:@"限时免费"];
                    long long new_tim = [[[categoryArray objectAtIndex:1] objectForKey:@"tim"] longLongValue];
                    long long old_tim = appClasses.appClasses_tim;
                    if (new_tim >old_tim) {
                        appClasses.appClasses_tim = new_tim;
                        [AppRecommedDao updateAppRecommend:appClasses];
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:NEWS_APP];
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:XSMF_APP];
                    }
                    NSLog(@"%@ 'sNEW_TIM IS %lld , OLD_TIM IS %lld",appClasses.appClasses_name,new_tim , old_tim);
                }
                if ([str isEqualToString:@"热门游戏"]) {
                    AppClasses *appClasses = [databaseDic objectForKey:@"热门游戏"];
                    long long new_tim = [[[categoryArray objectAtIndex:2] objectForKey:@"tim"] longLongValue];
                    long long old_tim = appClasses.appClasses_tim;
                    if (new_tim >old_tim) {
                        appClasses.appClasses_tim = new_tim;
                        [AppRecommedDao updateAppRecommend:appClasses];
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:NEWS_APP];
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:RMYX_APP];
                    }
                    NSLog(@"%@ 'sNEW_TIM IS %lld , OLD_TIM IS %lld",appClasses.appClasses_name,new_tim , old_tim);
                }
            }
        }
    }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    NSLog(@"proxyFlag is change old is %@ , new is %@ .",[change valueForKey:@"new"],[change valueForKey:@"old"]);
    [[NSNotificationCenter defaultCenter]postNotificationName:@"proxyflagischange" object:nil];
}


#pragma mark - UIApplication Delegate
/*! @brief AppDelegate的代理方法
 *
 * 应用程序第一次启动的时候会就会进入的方法，此方法中会做一些程序的初始化操作等
 *
 * @param application UIApplication应用程序实例对象 ， launchOptions 程序的一些初始首选项
 * @return 成功返回YES，失败返回NO。
 */

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions  
{
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];
    
    //向微信注册
    [WXApi registerApp:@"wxd1be1f55db841585"];
    
    //flurry注册
    [Flurry startSession:@"433YMQ24HNQK3JFNK98H"];
    [Flurry logEvent:@"USER_OPEN_APP"]; //统计软件开启次数
    //统计渠道
    BOOL flurry_channel = [[NSUserDefaults standardUserDefaults] boolForKey:@"flurry_channel"];
    if (!flurry_channel) {
        [Flurry logEvent:@"APP_CHANNEL" withParameters:[NSDictionary dictionaryWithObjectsAndKeys:CHANNEL ,@"channel_name" ,nil]];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"flurry_channel"];
    }
    
    timerTaskLock = [[NSObject alloc] init];
    timerTaskDoing = false;
    refreshingLock = [[NSLock alloc] init];
    
    NSString* version = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleVersionKey];
    NSLog(@"++++++++++++++++didFinishLaunchingWithOptions,version=%@", version);
    
    BOOL versionUpgrade = NO;
    NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
    NSString* oldVersion = [userDefaults objectForKey:@"version"];
    if ( !oldVersion ) {
        [userDefaults setObject:version forKey:@"version"];
        [userDefaults synchronize];
        oldVersion = @"0";
        versionUpgrade = YES;
    }
    else {
        if ( [version compare:oldVersion] != NSOrderedSame ) {
            [userDefaults setObject:version forKey:@"version"];
            [userDefaults synchronize];
            
            if ( [oldVersion compare:@"1.3"] == NSOrderedAscending ) {
                //1.3之前的版本，更新数据库
                versionUpgrade = YES;
            }
            else if ( [oldVersion compare:@"1.9.1"] == NSOrderedAscending &&
                     ([version compare:@"1.9.1"] == NSOrderedSame || [version compare:@"1.9.1"]==NSOrderedDescending) ) {
                //从1.9.1之前的版本，升级到1.9.1或1.9.1之后的版本，更新数据库
                versionUpgrade = YES;
            }
            else {
                versionUpgrade = NO;
            }
        }
    }
    
    //initialize database
    [self initDatabase:versionUpgrade];
    
    if ( !versionUpgrade ) {
        [self execUpgradeSQL:version oldVersion:oldVersion];
    }
    
    //创建应用分类的数据库表
    [AppRecommedDao createAppClassestable];
    //查看是否有新的应用推荐
    [self ifNewsApp];
    
    self.refreshDatastats = NO;
    self.refreshDatasave = NO;
    
    self.user = [UserSettings currentUserSettings];
    
    [user addObserver:self forKeyPath:@"proxyFlag" options:NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew context:nil];
    
    //获取用户sim卡信息
    CTTelephonyNetworkInfo* tni = [[CTTelephonyNetworkInfo alloc] init];
    self.carrier = tni.subscriberCellularProvider;
    [tni release];
    
    self.networkReachablity = [Reachability reachabilityWithHostName:P_HOST];
    
    internetReachablity = [[Reachability reachabilityForInternetConnection] retain];
    [internetReachablity startNotifier];
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(reachabilityChanged:) name: kReachabilityChangedNotification object: nil];
     
    connType = [UIDevice connectionType];
    proxySlow = NO;
    
        
#ifdef DFTraffic
    [AiDfTraffic startAiDfTrafficPluginWithBussinessId:@"1-1-2"];
#endif
    
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    //判断iOS版本
    float systemVersion = [[UIDevice currentDevice].systemVersion floatValue];
    
    //根据判断来添加页面元素
    if ( systemVersion < 4.0 ) {
        NSString* v = [[NSUserDefaults standardUserDefaults] objectForKey:@"systemVersion"];
        if ( v ) {
            [self showDatasaveView:NO]; 
        }
        else {
            [self showSetupView];
        }
    }
    else {
        float currentCapacity = [UserSettings currentCapacity];
        NSLog(@"currentCapacity=%f", currentCapacity);
        if ( currentCapacity == 0 ) {
            [self showSetupView];
        }
        else {
            [self showDatasaveView:NO];
        }
        
    }
    
    [self.window makeKeyAndVisible];  
    
    //定位
    locationManager = [[TCLocationManager alloc] init];
    BOOL b = [[NSUserDefaults standardUserDefaults] boolForKey:UD_LOCATION_ENABLED];
    if ( b ) {
        if ( ![CLLocationManager locationServicesEnabled] ) {
            b = NO;
        }
        else if ( [CLLocationManager authorizationStatus] != kCLAuthorizationStatusAuthorized ) {
            b = NO;
        }
        
        if ( b ) {
            [locationManager startManager];
        }
        else {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UD_LOCATION_ENABLED];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    }
    
//    //parse web 上面项目的注册码
//    [Parse setApplicationId:@"Kon5U86c1l2Huj4CIsoq9EnGtE4hHLgwPVnCCBhA"
//                  clientKey:@"RAw1BSXR9VG1th7HrkoeDG2Smn0sdJIJwhITKagc"];
    
    //注册推送通知
    [[UIApplication sharedApplication] registerForRemoteNotificationTypes:UIRemoteNotificationTypeBadge|UIRemoteNotificationTypeSound|UIRemoteNotificationTypeAlert];
    
    //判断程序是不是由推送服务完成的
    if (launchOptions) {
        NSDictionary* pushNotificationKey = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
        if (pushNotificationKey) {
            
            //推送进来可以在这里处理，比如说跳转到什么页面。
            //            UIAlertView *alert = [[UIAlertView alloc]initWithTitle:@"推送通知"
            //                                                           message:@"这是通过推送窗口启动的程序，你可以在这里处理推送内容"
            //                                                          delegate:nil
            //                                                 cancelButtonTitle:@"知道了"
            //                                                 otherButtonTitles:nil, nil];
            //            [alert show];
            //            [alert release];
            [self performSelector:@selector(processRemoteNotification:) withObject:pushNotificationKey afterDelay:0.5f];
        }
    }

    //
    NSDictionary* userInfo = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
    if ( userInfo ) {
        [self performSelector:@selector(processRemoteNotification:) withObject:userInfo afterDelay:0.5f];
        //[self performSelectorOnMainThread:@selector(processRemoteNotification:) withObject:userInfo waitUntilDone:NO];
    }

    refreshThread = [[NSThread alloc] initWithTarget:self selector:@selector(runRefresh:) object:nil];
    [refreshThread start];
    
    return YES;
}

//程序恢复
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    /*
     Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
     */
    NSLog(@"++++++++++++++applicationDidBecomeActive");
    float currentCapacity = [UserSettings currentCapacity];
    if ( currentCapacity > 0 ) {
        
        //获得用户的 可压缩数据的数值
        [self incrDayCapacity];
        
        //访问getMemberInfo接口
        [self getMemberInfo];
        
    }
    
    /*if ( !timer || !timer.isValid ) {
     [self performSelector:@selector(startTimer) withObject:nil afterDelay:60];
     }*/
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    /*
     Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
     Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
     */
    NSLog(@"++++++++++++++applicationWillResignActive");
    /*if ( timer && timer.isValid ) {
        [timer invalidate];
        timer = nil;
    }*/
}


- (void)applicationDidEnterBackground:(UIApplication *)application
{
    /*
     Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
     If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
     */
    [Flurry logEvent:@"APP_GO_BACKGROUND"];//应用程序被挂起的次数
    
    NSLog(@"++++++++++++++applicationDidEnterBackground");
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    /*
     Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
     */
    NSLog(@"++++++++++++++applicationWillEnterForeground");
}



- (void)applicationWillTerminate:(UIApplication *)application
{
    NSLog(@"++++++++++++++applicationWillTerminate");
    /*if ( timer && timer.isValid ) {
        [timer invalidate];
        timer = nil;
    }*/
}

/*
// Optional UITabBarControllerDelegate method.
- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController
{
}
*/

/*
// Optional UITabBarControllerDelegate method.
- (void)tabBarController:(UITabBarController *)tabBarController didEndCustomizingViewControllers:(NSArray *)viewControllers changed:(BOOL)changed
{
}
*/
- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url 
{
    NSString* urlString = [url absoluteString];
    NSLog(@"application:handleOpenURL: %@", urlString);
    //?取消的情况下如何调用？
    
    if ( !user ) self.user = [UserSettings currentUserSettings];
    
    NSRange range = [urlString rangeOfString:@"flashapp://"];
    if ( range.location == 0 ) {
        NSString* page = [urlString substringFromIndex:11];
        
        if ( [page length] > 0 ) {
            NSDictionary* params = [TwitterClient urlParameters:page];
            NSArray* array = [page componentsSeparatedByString:@"?"];
            NSString* queryString = nil;
            if ( [array count] > 1 ) {
                page = [array objectAtIndex:0];
                queryString = [array objectAtIndex:1];
            }
            
            //profile已经安装
            if ( queryString ) {
                NSString* setInstall = [params objectForKey:@"setInstall"];
                NSString* status = [params objectForKey:@"status"];
                NSString* capacity = [params objectForKey:@"quantity"];
                user.capacity = [capacity floatValue];
                user.status = [status intValue];
                
                //判断是否在审核， 1.在审核  ; 2.没在审核
                [UserSettings saveInchk:[params objectForKey:@"inchk"]];
                
                NSString* idcCode = [params objectForKey:@"code"];
                if ( idcCode && idcCode.length > 0 ) {
                    user.idcCode = idcCode;
                }
                else {
                    user.idcCode = P_IDC_CODE;
                }

                NSString* server = [params objectForKey:@"svr"];
                if ( server && server.length > 0 ) {
                    user.idcServer = server;
                }
                
                NSString* proxyServer = [params objectForKey:@"domain"];
                if ( proxyServer && proxyServer.length > 0 ) {
                    user.proxyServer = proxyServer;
                }
                
                NSString* proxyPort = [params objectForKey:@"port"];
                if ( proxyPort && proxyPort.length > 0 ) {
                    user.proxyPort = [proxyPort intValue];
                }

                //1 是安装 0 是卸载
                if ( [@"1" compare:setInstall] == NSOrderedSame ) {
                    NSString* stype = [params objectForKey:@"stype"];
                    if ( stype ) {
                        user.stype = stype;
                    }

                    if ( [@"vpn" isEqualToString:user.stype] ) {
                        user.proxyFlag = INSTALL_FLAG_VPN_RIGHT_IDC_PAC;
                    }
                    else {
                        user.proxyFlag = INSTALL_FLAG_APN_RIGHT_IDC;
                    }
                }
                else {
                    //这里要判断用户是否真的卸载了描述文件
                    
                    [UserSettings saveCapacity:[capacity floatValue] status:[status intValue] proxyFlag:INSTALL_FLAG_NO];
                    user.proxyFlag = INSTALL_FLAG_NO;
                }
                
                [UserSettings saveUserSettings:user];
            }
            
            
            /*if ( [@"register" compare:page] == NSOrderedSame ) {
                [self showRegisterView];
                return YES;
            }
            if ( [@"datasave" compare:page] == NSOrderedSame ) {
                UIViewController* controller = [self currentViewController];
                if ( [controller isKindOfClass:[DataServiceViewController class]] ) {
                    DataServiceViewController* dataController = (DataServiceViewController*) controller;
                    [dataController showConnectMessage];
                }
                return YES;
            }
            else {
                UIViewController* controller = [self currentViewController];
                if ( [controller isKindOfClass:[DataServiceViewController class]] ) {
                    DataServiceViewController* dataController = (DataServiceViewController*) controller;
                    [dataController showConnectMessage];
                }
                return YES;
            }*/
            
            if ( [@"datasave" compare:page] == NSOrderedSame ) {
                [self showDatasaveView:YES];
            }
            else {
                UIViewController* controller = [self currentViewController];
                //如果是setting界面，则需要刷新服务状态
                if ( [controller isKindOfClass:[SettingViewController class]] ) {
                    SettingViewController* settingController = (SettingViewController*) controller;
                    //[settingController showProfileStatusCell];
                    [settingController refresh];
                }
                else if ( [controller isKindOfClass:[IDCPickerViewController class]] ) {
                    IDCPickerViewController* idcController = (IDCPickerViewController*) controller;
                    [idcController refreshTable];
                }
                else if ( [controller isKindOfClass:[HelpNetBadViewController class]] ) {
                    HelpNetBadViewController* helpController = (HelpNetBadViewController*) controller;
                    [helpController refreshProfileStatus];
                }
                else if ( [controller isKindOfClass:[HelpCompressViewController class]] ) {
                    HelpCompressViewController* helpController = (HelpCompressViewController*) controller;
                    [helpController check];
                }
                else if ( [controller isKindOfClass:[DatasaveViewController class]] ) {
                    DatasaveViewController* dataController = (DatasaveViewController*) controller;
                    [dataController checkProfile];
                }
            }

            return YES;
        }
    }
    
    NSRange qqLoginRange = [urlString rangeOfString:@"tencent100286927"];
    if (qqLoginRange.length > 0) {
        return [TencentOAuth HandleOpenURL:url];
    }
    
    //For微信SDK
    return  [WXApi handleOpenURL:url delegate:self];
//    return YES;
}


//- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
//{
//    //For微信SDK
//    return  [WXApi handleOpenURL:url delegate:self];
//}


#pragma mark -- APNS Notification 
- (void) application:(UIApplication*)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    NSString* s = [deviceToken description];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
    s = [s stringByReplacingOccurrencesOfString:@" " withString:@""];
    
#ifdef DEBUG
        s=[NSString stringWithFormat:@":%@",s];
        NSLog(@"debug deviceToken=%@", s);
#endif
    NSLog(@"deviceToken=%@", s);
    NSUserDefaults* userDefault = [NSUserDefaults standardUserDefaults];
    [userDefault setObject:s forKey:@"deviceToken"];
    [userDefault synchronize];
    
    // Store the deviceToken in the current installation and save it to Parse.
//    PFInstallation *currentInstallation = [PFInstallation currentInstallation];
//    [currentInstallation setDeviceTokenFromData:deviceToken];
//    [currentInstallation saveInBackground];
}
- (void) application:(UIApplication*)application didReceiveRemoteNotification:(NSDictionary *)userInfo
{
    //自身服务器的方法
    [self performSelectorOnMainThread:@selector(processRemoteNotification:) withObject:userInfo waitUntilDone:NO];
    
    //parse 服务器的方法
    //    [PFPush handlePush:userInfo];
}


- (void) application:(UIApplication*)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    if ( error ) {
        if ( [error localizedDescription] ) {
            NSLog( @"++++++++++++++++1Faild to get token:%@", [error localizedDescription] );
        }
        if ( [error localizedFailureReason] ) {
            NSLog( @"++++++++++++++++2Faild to get token:%@", [error localizedFailureReason] );
        }
        if ( [error localizedRecoverySuggestion] ) {
            NSLog( @"++++++++++++++++3Faild to get token:%@", [error localizedRecoverySuggestion] );
        }
    }
    NSLog( @"++++++++++++++++4Faild to get token:%@", [error description]);
}

#pragma mark - install profile

+ (NSString*) getInstallURLForServiceType:(NSString*)serviceType nextPage:(NSString*)nextPage install:(BOOL)isInstall apn:(NSString*)apn idc:(NSString*)idcCode interfable:(NSString *)inter
{
    DeviceInfo* device = [DeviceInfo deviceInfoWithLocalDevice];
    NSString* type = [UIDevice connectionTypeString];
    
    //获得Sim卡运行商
    CTTelephonyNetworkInfo* tni = [[CTTelephonyNetworkInfo alloc] init];
    CTCarrier* carrier = tni.subscriberCellularProvider;
    [tni release];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *languages = [defaults objectForKey:@"AppleLanguages"];
    NSString *currentLanguage = [languages objectAtIndex:0];
    if ( !currentLanguage || currentLanguage.length == 0 ) currentLanguage = @"en";
    
    NSString* action = @"vpnn";
    NSMutableString* url = [NSMutableString stringWithFormat:@"http://%@/%@?_method=profile&servicetype=%@&name=%@&platform=%@&osversion=%@&connType=%@&carrier=%@&mcc=%@&mnc=%@&install=%d&apn=%@%@&lang=%@&interfable=%@",
                            P_HOST, action, serviceType,
                            [device.hardware encodeAsURIComponent], [device.platform encodeAsURIComponent],
                            [device.version encodeAsURIComponent], type,
                            carrier ? [carrier.carrierName encodeAsURIComponent] : @"",
                            carrier ? carrier.mobileCountryCode : @"",
                            carrier ? carrier.mobileNetworkCode : @"",
                            isInstall ? 1 : 0,
                            apn && [apn length] > 0 ? [apn encodeAsURIComponent] : @"",
                            idcCode ? [NSString stringWithFormat:@"&area=%@", idcCode] : @"",
                            currentLanguage,inter];
    if ( nextPage && [nextPage length] > 0 ) {
        [url appendFormat:@"&nextPage=%@", [nextPage encodeAsURIComponent]];
    }
    
    NSString* s = [TwitterClient composeURLVerifyCode:url];
    NSLog(@"%@", s);
    return s;
}



+ (void) installProfile:(NSString *)nextPage idc:(NSString*)idcCode
{
    NSUserDefaults* userDefault = [NSUserDefaults standardUserDefaults];
    NSString* apn = [userDefault objectForKey:@"apnName"];
    NSString* stype = [AppDelegate getAppDelegate].user.stype;
    [self installProfileForServiceType:stype nextPage:nextPage apn:apn idc:idcCode interfable:@"0"];
}


+ (void) installProfile:(NSString *)nextPage apn:(NSString*)apn
{
    NSUserDefaults* userDefault = [NSUserDefaults standardUserDefaults];
    if ( apn && [apn length] > 0 ) {
        [userDefault setObject:apn forKey:@"apnName"];
    }
    else {
        [userDefault removeObjectForKey:@"apnName"];
    }
    [userDefault synchronize];
    
    
    NSString* stype = [AppDelegate getAppDelegate].user.stype;
    [self installProfileForServiceType:stype nextPage:nextPage apn:apn idc:nil interfable:@"0"];
}


+ (void) installProfile:(NSString*)nextPage
{
    NSString* stype = [AppDelegate getAppDelegate].user.stype;
    NSString* apn = [[NSUserDefaults standardUserDefaults] objectForKey:@"apnName"];
    [self installProfileForServiceType:stype nextPage:nextPage apn:apn idc:nil interfable:@"0"];
}

// 1.程序第一次启动的时候 serviceType = @"apn" , interfable = @"1"
// 2.vpn帮助页面提示开启服务按钮 ， serviceType = @"apn" nextPage = @"datasave" interfable = inchk?1:0
+ (void) installProfileForServiceType:(NSString*)serviceType nextPage:(NSString*)nextPage apn:(NSString*)apn idc:(NSString*)idcCode interfable:(NSString *)inter
{
    NSString* url = [AppDelegate getInstallURLForServiceType:serviceType nextPage:nextPage install:YES apn:apn idc:idcCode interfable:inter];
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
}


+ (void) uninstallProfile:(NSString*)nextPage
{
    NSUserDefaults* userDefault = [NSUserDefaults standardUserDefaults];
    NSString* apn = [userDefault objectForKey:@"apnName"];
    NSString* stype = [AppDelegate getAppDelegate].user.stype;
    
    NSString* url = [AppDelegate getInstallURLForServiceType:stype nextPage:nextPage install:NO apn:apn idc:nil interfable:@"0"];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
}



#pragma mark - refresh timer methods

- (void) runRefresh:(void*)unused
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
    
    NSDate* date = [NSDate dateWithTimeIntervalSinceNow:60];
    NSTimer* timer = [[NSTimer alloc] initWithFireDate:date interval:1800 target:self selector:@selector(timerTask) userInfo:nil repeats:YES];
    [runLoop addTimer:timer forMode:NSDefaultRunLoopMode];
    
    [runLoop run];
    [pool release];
}


/*
- (void) startTimer
{
    timer = [NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(timerTask) userInfo:nil repeats:YES];
    [timer fire];
}*/


- (void) timerTask
{
    if ( timerTaskDoing ) return;
    if ( [networkReachablity currentReachabilityStatus] != NotReachable ) {
        @synchronized (timerTaskLock) {
            if ( !timerTaskDoing ) {
                timerTaskDoing = YES;

                [TCUtils readIfData:-1];
                [TwitterClient getStatsData];
                
                InstallFlag proxyFlag = user.proxyFlag;
                connType = [UIDevice connectionType];
                
                proxySlow = NO;
                if ( connType == CELL_2G || connType == CELL_3G || connType == CELL_4G ) {
                    if ( proxyFlag == INSTALL_FLAG_APN_RIGHT_IDC || proxyFlag == INSTALL_FLAG_APN_WRONG_IDC ) {
                        proxySlow = [self proxyServerSlow];
                    }
                }
                
                [[NSNotificationCenter defaultCenter] postNotificationName:RefreshNotification object:nil];
                
                timerTaskDoing = NO;
            }
        }
    }
}


- (void) reachabilityChanged: (NSNotification* )note
{
	Reachability* curReach = [note object];
    NetworkStatus netStatus = [curReach currentReachabilityStatus];
    switch (netStatus)
    {
        case ReachableViaWWAN:
        case ReachableViaWiFi:
            [[NSNotificationCenter defaultCenter] postNotificationName:RefreshNotification object:nil];
            break;
        default: {
            
        }
    }
}

#pragma mark - app info

- (void) uploadAppInfo
{
    NSMutableDictionary* currentApps = [[UIDevice currentDevice] getInstalledApps];
    NSString* jsonString = [self appInfoToJSONString:currentApps];
    
    BOOL r = [TwitterClient uploadAppInfoSync:jsonString];
    if ( r ) {
        NSMutableDictionary* lastApps = [NSMutableDictionary dictionary];
        NSArray* keys = [currentApps allKeys];
        AppInfo* app;
        for ( NSString* key in keys ) {
            app = [currentApps objectForKey:key];
            [lastApps setObject:app.bundleID forKey:key];
        }
        
        [[NSUserDefaults standardUserDefaults] setObject:lastApps forKey:@"apps"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}


- (NSString*) appInfoToJSONString:(NSDictionary*)currentApps
{
    NSMutableDictionary* lastApps = [[NSUserDefaults standardUserDefaults] objectForKey:@"apps"];
    
    NSMutableString* addString = [NSMutableString string];
    [addString appendString:@"["];
    
    NSMutableString* updateString = [NSMutableString string];
    [updateString appendString:@"["];

    NSMutableString* deleteString = [NSMutableString string];
    [deleteString appendString:@"["];

    NSArray* keys = [currentApps allKeys];
    AppInfo* currentAppInfo;
    //AppInfo* lastAppInfo;
    NSString* lastAppInfo;
    
    for ( NSString* key in keys ) {
        currentAppInfo = (AppInfo*) [currentApps objectForKey:key];
        lastAppInfo = [lastApps objectForKey:key];
        [lastApps removeObjectForKey:key];
        
        if ( !lastAppInfo ) {
            [addString appendFormat:@"{%@},", [currentAppInfo briefJsonString]];
        }
        //else if ( ![currentAppInfo isSame:lastAppInfo] ) {
        //    [updateString appendFormat:@"{%@},", [currentAppInfo briefJsonString]];
        //}
    }
    
    keys = [lastApps allKeys];
    for ( NSString* key in keys ) {
        lastAppInfo = [lastApps objectForKey:key];
        //[deleteString appendFormat:@"{%@},", [lastAppInfo briefJsonString]];
        [deleteString appendFormat:@"{id:'%@',name:'',ver:''},", lastAppInfo];
    }
    
    if ( addString.length > 1 ) {
        NSRange range;
        range.location = addString.length - 1;
        range.length = 1;
        [addString deleteCharactersInRange:range];
    }
    [addString appendString:@"]"];
    
    if ( updateString.length > 1 ) {
        NSRange range;
        range.location = updateString.length - 1;
        range.length = 1;
        [updateString deleteCharactersInRange:range];
    }
    [updateString appendString:@"]"];

    if ( deleteString.length > 1 ) {
        NSRange range;
        range.location = deleteString.length - 1;
        range.length = 1;
        [deleteString deleteCharactersInRange:range];
    }
    [deleteString appendString:@"]"];

    NSString* jsonString = [NSString stringWithFormat:@"{deviceid:'%@', add:%@, update:%@, delete:%@}", [OpenUDID value], addString, updateString, deleteString];
    
    return jsonString;
}


#pragma mark - 微信sdk

- (void) onReq:(BaseReq*)req
{
    
}


- (void) onResp:(BaseResp*)resp
{
    if([resp isKindOfClass:[SendMessageToWXResp class]])
    {
        NSString *strTitle = [NSString stringWithFormat:@"发送结果"];
        NSString* strMsg = nil;
        if ( resp.errCode == 0 ) {
            strMsg = @"已经成功发送微信！";
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:strTitle message:strMsg delegate:self cancelButtonTitle:@"确定" otherButtonTitles:nil, nil];
            [alert show];
            [alert release];
        }
    }
    else if([resp isKindOfClass:[SendAuthResp class]])
    {
        NSString *strTitle = [NSString stringWithFormat:@"Auth结果"];
        NSString *strMsg = [NSString stringWithFormat:@"Auth结果:%d", resp.errCode];
        
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:strTitle message:strMsg delegate:self cancelButtonTitle:@"OK" otherButtonTitles:nil, nil];
        [alert show];
        [alert release];
    }
    
}

@end
