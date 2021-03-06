//
//  UsersViewController.m
//  sample-videochat-webrtc
//
//  Copyright © 2019 Quickblox. All rights reserved.
//

#import "UsersViewController.h"

#import <Quickblox/Quickblox.h>
#import <PushKit/PushKit.h>
#import "UsersDataSource.h"
#import "PlaceholderGenerator.h"
#import "CallPermissions.h"
#import "SessionSettingsViewController.h"
#import "SVProgressHUD.h"
#import "CallViewController.h"
#import "CallKitManager.h"
#import "UIViewController+InfoScreen.h"
#import "Profile.h"
#import "Reachability.h"
#import "Log.h"
#import "AppDelegate.h"

const NSUInteger kQBPageSize = 50;
static NSString * const kAps = @"aps";
static NSString * const kAlert = @"alert";
static NSString * const kVoipEvent = @"VOIPCall";
NSString *const DEFAULT_PASSOWORD = @"quickblox";

typedef NS_ENUM(NSUInteger, ErrorDomain) {
    
    ErrorDomainSignUp,
    ErrorDomainLogIn,
    ErrorDomainLogOut,
    ErrorDomainChat,
};

@interface UsersViewController () <QBRTCClientDelegate, SettingsViewControllerDelegate, PKPushRegistryDelegate>

@property (weak, nonatomic) IBOutlet UIBarButtonItem *audioCallButton;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *videoCallButton;

@property (strong, nonatomic) UsersDataSource *dataSource;
@property (strong, nonatomic) UINavigationController *navViewController;
@property (weak, nonatomic) QBRTCSession *session;

@property (strong, nonatomic) PKPushRegistry *voipRegistry;

@property (strong, nonatomic) NSUUID *callUUID;
@property (assign, nonatomic) UIBackgroundTaskIdentifier backgroundTask;

@end

@implementation UsersViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _backgroundTask = UIBackgroundTaskInvalid;
    
    [QBRTCClient.instance addDelegate:self];
    // Reachability
    __weak __typeof(self)weakSelf = self;
    Reachability.instance.networkStatusBlock = ^(QBNetworkStatus status) {
        if (status != QBNetworkStatusNotReachable) {
            [weakSelf loadUsers];
        }
    };
    
    [self configureNavigationBar];
    [self configureTableViewController];
    [self setToolbarButtonsEnabled:NO];
    [self loadUsers];
    
    self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.voipRegistry.delegate = self;
    self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    //MARK: - Reachability
    void (^updateConnectionStatus)(QBNetworkStatus status) = ^(QBNetworkStatus status) {
        
        if (status == QBNetworkStatusNotReachable) {
            [self cancelCallAlert];
        } else {
            [self loadUsers];
        }
    };
    Reachability.instance.networkStatusBlock = ^(QBNetworkStatus status) {
        updateConnectionStatus(status);
    };
    
    if (self.refreshControl.refreshing) {
        [self.tableView setContentOffset:CGPointMake(0, -self.refreshControl.frame.size.height) animated:NO];
    }
    self.navigationController.toolbarHidden = NO;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    self.navigationController.toolbarHidden = YES;
}

#pragma mark - UI Configuration

- (void)configureTableViewController {
    
    _dataSource = [[UsersDataSource alloc] init];
    CallKitManager.instance.usersDatasource = _dataSource;
    
    self.tableView.dataSource = _dataSource;
    self.tableView.rowHeight = 44;
    [self.refreshControl beginRefreshing];
}

- (void)configureNavigationBar {
    
    UIBarButtonItem *settingsButtonItem =
    [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"ic-settings"]
                                     style:UIBarButtonItemStylePlain
                                    target:self
                                    action:@selector(didPressSettingsButton:)];
    
    self.navigationItem.leftBarButtonItem = settingsButtonItem;
    //Custom label
    
    Profile *profile = [[Profile alloc] init];
    NSString *roomName = [NSString stringWithFormat:@"%@", profile.tag];
    NSString *loggedString = [NSString stringWithFormat:@"Logged in as "];
    NSString *fullName = profile.fullName;
    NSString *titleString = [NSString stringWithFormat:@"%@%@", loggedString, fullName];
    if (profile.tag) {
        titleString = [NSString stringWithFormat:@"%@\n%@", roomName, loggedString];
    }
    
    
    NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] initWithString:titleString];
    NSRange roomNameRange = [titleString rangeOfString:roomName];
    [attrString addAttribute:NSFontAttributeName
                       value:[UIFont boldSystemFontOfSize:16.0f]
                       range:roomNameRange];
    
    NSRange userNameRange = [titleString rangeOfString:loggedString];
    [attrString addAttribute:NSFontAttributeName
                       value:[UIFont systemFontOfSize:12.0f]
                       range:userNameRange];
    [attrString addAttribute:NSForegroundColorAttributeName
                       value:[UIColor grayColor]
                       range:userNameRange];
    
    UILabel * titleView = [[UILabel alloc] initWithFrame:CGRectZero];
    titleView.numberOfLines = 2;
    titleView.attributedText = attrString;
    titleView.textAlignment = NSTextAlignmentCenter;
    [titleView sizeToFit];
    
    self.navigationItem.titleView = titleView;
    //Show tool bar
    self.navigationController.toolbarHidden = NO;
    //Set exclusive touch for tool bar
    for (UIView *subview in self.navigationController.toolbar.subviews) {
        [subview setExclusiveTouch:YES];
    }
    //add info button
    [self showInfoButton];
}
/**
 *  Load all (Recursive) users for current room (tag)
 */
- (void)loadUsers {
    
    QBGeneralResponsePage *firstPage = [QBGeneralResponsePage responsePageWithCurrentPage:1 perPage:100];
    __weak __typeof(self)weakSelf = self;
    [QBRequest usersWithExtendedRequest:@{@"order": @"desc date updated_at"} page:firstPage successBlock:^(QBResponse * _Nonnull response, QBGeneralResponsePage * _Nonnull page, NSArray<QBUUser *> * _Nonnull users) {
        [weakSelf.refreshControl endRefreshing];
        [weakSelf.dataSource updateUsers:users];
        [weakSelf.tableView reloadData];
    } errorBlock:^(QBResponse * _Nonnull response) {
        [weakSelf.refreshControl endRefreshing];
    }];
}

#pragma mark - Actions

- (void)didPressRecordsButton:(UIBarButtonItem *)item {
    
    [self performSegueWithIdentifier:@"PresentRecordsViewController" sender:item];
}

- (IBAction)refresh:(UIRefreshControl *)sender {
    
    [self loadUsers];
}

- (IBAction)didPressAudioCall:(UIBarButtonItem *)sender {
    
    [self callWithConferenceType:QBRTCConferenceTypeAudio];
}

- (IBAction)didPressVideoCall:(UIBarButtonItem *)sender {
    
    [self callWithConferenceType:QBRTCConferenceTypeVideo];
}

- (void)callWithConferenceType:(QBRTCConferenceType)conferenceType {
    
    if (self.session) {
        return;
    }
    
    Profile *profile = [[Profile alloc] init];
    
    if ([self hasConnectivity]) {
        
        [CallPermissions checkPermissionsWithConferenceType:conferenceType completion:^(BOOL granted) {
            
            __weak __typeof(self)weakSelf = self;
            
            if (granted) {
                
                NSArray *opponentsIDs = [weakSelf.dataSource idsForUsers:weakSelf.dataSource.selectedUsers];
                //Create new session
                QBRTCSession *session =
                [QBRTCClient.instance createNewSessionWithOpponents:opponentsIDs
                                                 withConferenceType:conferenceType];
                if (session) {
                    
                    weakSelf.session = session;
                    NSUUID *uuid = [NSUUID UUID];
                    weakSelf.callUUID = uuid;
                    
                    [CallKitManager.instance startCallWithUserIDs:opponentsIDs session:session uuid:uuid];
                    
                    CallViewController *callViewController = [weakSelf.storyboard instantiateViewControllerWithIdentifier:@"CallViewController"];
                    callViewController.session = weakSelf.session;
                    callViewController.usersDatasource = weakSelf.dataSource;
                    callViewController.callUUID = uuid;
                    
                    weakSelf.navViewController = [[UINavigationController alloc] initWithRootViewController:callViewController];
                    weakSelf.navViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
                    
                    [self presentViewController:self.navViewController animated:NO completion:^{
                        __weak __typeof(self)weakSelf = self;
                        weakSelf.audioCallButton.enabled = NO;
                        weakSelf.videoCallButton.enabled = NO;
                    }];
                    
                    NSString *name = profile.fullName.length > 0 ? profile.fullName : @"Unknown user";
                    
                    NSDictionary *payload = @{
                                              @"message"  : [NSString stringWithFormat:@"%@ is calling you.", name],
                                              @"ios_voip" : @"1",
                                              kVoipEvent  : @"1",
                                              };
                    NSData *data =
                    [NSJSONSerialization dataWithJSONObject:payload
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:nil];
                    NSString *message =
                    [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
                    
                    QBMEvent *event = [QBMEvent event];
                    event.notificationType = QBMNotificationTypePush;
                    event.usersIDs = [opponentsIDs componentsJoinedByString:@","];
                    event.type = QBMEventTypeOneShot;
                    event.message = message;
                    
                    [QBRequest createEvent:event
                              successBlock:^(QBResponse *response, NSArray<QBMEvent *> *events) {
                                  Log(@"[%@] Send voip push - Success",  NSStringFromClass([UsersViewController class]));
                              } errorBlock:^(QBResponse * _Nonnull response) {
                                  Log(@"[%@] Send voip push - Error",  NSStringFromClass([UsersViewController class]));
                              }];
                }
                else {
                    
                    [SVProgressHUD showErrorWithStatus:@"You should login to use VideoChat API. Session hasn’t been created. Please try to relogin."];
                }
            }
        }];
    }
}

- (BOOL)hasConnectivity {
    
    BOOL hasConnectivity = Reachability.instance.networkStatus != QBNetworkStatusNotReachable;
    
    if (!hasConnectivity) {
        [self showAlertViewWithMessage:NSLocalizedString(@"Please check your Internet connection", nil)];
    }
    
    return hasConnectivity;
}

- (void)showAlertViewWithMessage:(NSString *)message {
    
    UIAlertController *alertController =
    [UIAlertController alertControllerWithTitle:nil
                                        message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Ok", nil)
                                                        style:UIAlertActionStyleDefault
                                                      handler:nil]];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)didPressSettingsButton:(UIBarButtonItem *)item {
    UIStoryboard *settingsStoryboard = [UIStoryboard storyboardWithName:@"Settings" bundle:nil];
    SessionSettingsViewController *settingsController = [settingsStoryboard instantiateViewControllerWithIdentifier:@"SessionSettingsViewController"];
    settingsController.delegate = self;
    [self.navigationController pushViewController:settingsController animated:YES];
}

#pragma mark - SettingsViewControllerDelegate

- (void)settingsViewController:(SessionSettingsViewController *)vc didPressLogout:(id)sender {
    [self logoutAction];
}

- (void)logoutAction {
    if (QBChat.instance.isConnected == NO) {
        [SVProgressHUD showErrorWithStatus:@"Error"];
        return;
    }
    [SVProgressHUD showSuccessWithStatus:NSLocalizedString(@"SA_STR_LOGOUTING", nil)];
    [SVProgressHUD setDefaultMaskType:SVProgressHUDMaskTypeClear];
    
#if TARGET_OS_SIMULATOR
    [self disconnectUser];
#else
    NSString *deviceIdentifier = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    
    [QBRequest subscriptionsWithSuccessBlock:^(QBResponse * _Nonnull response, NSArray<QBMSubscription *> * _Nullable objects) {
        for (QBMSubscription *subscription in objects) {
            if ([subscription.deviceUDID isEqualToString:deviceIdentifier] && subscription.notificationChannel == QBMNotificationChannelAPNSVOIP) {
                [self unregisterSubscriptionForUniqueDeviceIdentifier:deviceIdentifier];
                return;
            }
        }
        [self disconnectUser];
    } errorBlock:^(QBResponse * _Nonnull response) {
        if (response.status == 404) {
            [self disconnectUser];
        }
    }];
#endif
}

- (void)unregisterSubscriptionForUniqueDeviceIdentifier:(NSString *)deviceIdentifier {
    [QBRequest unregisterSubscriptionForUniqueDeviceIdentifier:deviceIdentifier successBlock:^(QBResponse *response) {
        
        [self disconnectUser];
        
    } errorBlock:^(QBError *error) {
        if (error) {
            [SVProgressHUD showErrorWithStatus:error.error.localizedDescription];
            return;
        }
        [SVProgressHUD dismiss];
    }];
}

- (void)disconnectUser {
    [QBChat.instance disconnectWithCompletionBlock:^(NSError * _Nullable error) {
        if (error) {
            [SVProgressHUD showErrorWithStatus:error.localizedDescription];
            return;
        }
        [self logOut];
    }];
}

- (void)logOut {
    __weak __typeof(self)weakSelf = self;
    [QBRequest logOutWithSuccessBlock:^(QBResponse * _Nonnull response) {
        __typeof(weakSelf)strongSelf = weakSelf;
        
        //ClearProfile
        [Profile clearProfile];
        [SVProgressHUD dismiss];
        //Dismiss Settings view controller
        [strongSelf dismissViewControllerAnimated:NO completion:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.navigationController popToRootViewControllerAnimated:NO];
        });
        [SVProgressHUD showSuccessWithStatus:NSLocalizedString(@"Complited", nil)];
        
    } errorBlock:^(QBResponse * _Nonnull response) {
        if (response.error.error) {
            [SVProgressHUD showErrorWithStatus:response.error.error.localizedDescription];
            return;
        }
    }];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    
    [self.dataSource selectUserAtIndexPath:indexPath];
    [self setupToolbarButtons];
    [tableView reloadData];
}

#pragma mark - QBCallKitDataSource

- (NSString *)userNameForUserID:(NSNumber *)userID sender:(id)sender {
    
    QBUUser *user = [self.dataSource userWithID:userID.unsignedIntegerValue];
    return user.fullName;
}

#pragma mark - Helpers
- (void)setToolbarButtonsEnabled:(BOOL)enabled {
    
    for (UIBarButtonItem *item in self.toolbarItems) {
        item.enabled = enabled;
    }
}

- (void)setupToolbarButtons {
    [self setToolbarButtonsEnabled:self.dataSource.selectedUsers.count > 0];
    if (self.dataSource.selectedUsers.count > 4) {
        self.videoCallButton.enabled = NO;
    }
}

- (void)loadUserWithID:(NSUInteger)ID completion:(void(^)(QBUUser * _Nullable user))completion {
    [QBRequest userWithID:ID successBlock:^(QBResponse * _Nonnull response, QBUUser * _Nonnull user) {
        [self.dataSource updateUsers:@[user]];
        if (completion) {
            completion(user);
        }
    } errorBlock:^(QBResponse * _Nonnull response) {
        if (completion) {
            completion(nil);
        }
    }];
}

- (void)cancelCallAlert {
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Please check your Internet connection", nil) message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [CallKitManager.instance endCallWithUUID:self.callUUID completion:nil];
        [self prepareCloseCall];
    }];
    [alertController addAction:cancelAction];
    [self presentViewController:alertController animated:NO completion:^{
    }];
}

- (void)prepareCloseCall {
    self.session = nil;
    self.callUUID = nil;
    if (![QBChat instance].isConnected) {
        [self connectToChat];
    }
    [self setupToolbarButtons];
}

#pragma mark - QBWebRTCChatDelegate

- (void)session:(QBRTCSession *)session hungUpByUser:(NSNumber *)userID userInfo:(NSDictionary<NSString *,NSString *> *)userInfo {
    if (self.session.initiatorID.unsignedIntegerValue == userID.unsignedIntegerValue && !CallKitManager.instance.isCallDidStarted) {
        [CallKitManager.instance endCallWithUUID:self.callUUID completion:nil];
        [self prepareCloseCall];
    }
}

- (void)didReceiveNewSession:(QBRTCSession *)session userInfo:(NSDictionary *)userInfo {
    if (self.session != nil || CallKitManager.instance.isCallDidStarted) {
        [session rejectCall:@{@"reject" : @"busy"}];
        return;
    }
    
    self.session = session;
    NSUUID *uuid = [NSUUID UUID];
    self.callUUID = uuid;
    
    NSMutableArray *opponentIDs = [@[session.initiatorID] mutableCopy];
    Profile *profile = [[Profile alloc] init];
    
    for (NSNumber *userID in session.opponentsIDs) {
        if ([userID isEqualToNumber:@(profile.ID)]) {
            continue;
        }
        [opponentIDs addObject:userID];
    }
    
    __block NSString *callerName = @"";
    NSMutableArray *opponentNames = [NSMutableArray arrayWithCapacity:opponentIDs.count];
    NSMutableArray *newUsers = [NSMutableArray array];
    for (NSNumber *userID in opponentIDs) {
        QBUUser *user = [self.dataSource userWithID:userID.unsignedIntegerValue];
        if (user) {
            [opponentNames addObject:user.fullName];
        } else {
            [newUsers addObject:userID];
        }
    }
    
    if (newUsers.count) {
        __weak __typeof(self)weakSelf = self;
        dispatch_group_t loadGroup = dispatch_group_create();
        for (NSNumber *userID in newUsers) {
            dispatch_group_enter(loadGroup);
            [weakSelf loadUserWithID:userID.unsignedIntegerValue completion:^(QBUUser * _Nullable user) {
                if (user) {
                    [opponentNames addObject:user.fullName];
                } else {
                    [opponentNames addObject:@(user.ID)];
                }
                dispatch_group_leave(loadGroup);
            }];
        }
        dispatch_group_notify(loadGroup, dispatch_get_main_queue(), ^{
            callerName = [opponentNames componentsJoinedByString:@", "];
            [weakSelf reportIncomingCallWithUserIDs:opponentIDs.copy outCallerName:callerName session:session uuid:uuid];
        });
    } else {
        callerName = [opponentNames componentsJoinedByString:@", "];
        [self reportIncomingCallWithUserIDs:opponentIDs.copy outCallerName:callerName session:session uuid:uuid];
    }
}

- (void)reportIncomingCallWithUserIDs:(NSArray *)userIDs outCallerName:(NSString *)callerName session:(QBRTCSession *)session uuid:(NSUUID *)uuid {
    __weak __typeof(self)weakSelf = self;
    
    [CallKitManager.instance reportIncomingCallWithUserIDs:userIDs outCallerName:callerName session:session uuid:uuid onAcceptAction:^{
        __typeof(weakSelf)strongSelf = weakSelf;
        CallViewController *callViewController =
        [strongSelf.storyboard instantiateViewControllerWithIdentifier:@"CallViewController"];
        
        callViewController.session = session;
        callViewController.usersDatasource = strongSelf.dataSource;
        callViewController.callUUID = uuid;
        strongSelf.navViewController = [[UINavigationController alloc] initWithRootViewController:callViewController];
        [strongSelf presentViewController:strongSelf.navViewController animated:NO completion:nil];
        
    } completion:nil];
}

- (void)sessionDidClose:(QBRTCSession *)session {
    if ([session.ID isEqualToString: self.session.ID]) {
        if ([[self.navViewController presentingViewController] presentedViewController] == self.navViewController) {
            self.navViewController.view.userInteractionEnabled = NO;
            [self.navViewController dismissViewControllerAnimated:NO completion:nil];
            
        }
        [CallKitManager.instance endCallWithUUID:self.callUUID completion:nil];
        [self prepareCloseCall];
    }
}

// MARK: - PKPushRegistryDelegate protocol

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)pushCredentials forType:(PKPushType)type {
    
    //  New way, only for updated backend
    NSString *deviceIdentifier = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    
    QBMSubscription *subscription = [QBMSubscription subscription];
    subscription.notificationChannel = QBMNotificationChannelAPNSVOIP;
    subscription.deviceUDID = deviceIdentifier;
    subscription.deviceToken = pushCredentials.token;
    
    [QBRequest createSubscription:subscription successBlock:^(QBResponse *response, NSArray *objects) {
        Log(@"[%@] Create Subscription request - Success",  NSStringFromClass([UsersViewController class]));
    } errorBlock:^(QBResponse *response) {
        Log(@"[%@] Create Subscription request - Error",  NSStringFromClass([UsersViewController class]));
    }];
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    NSString *deviceIdentifier = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    [QBRequest unregisterSubscriptionForUniqueDeviceIdentifier:deviceIdentifier successBlock:^(QBResponse * _Nonnull response) {
        Log(@"[%@] Unregister Subscription request - Success",  NSStringFromClass([UsersViewController class]));
    } errorBlock:^(QBError * _Nonnull error) {
        Log(@"[%@] Unregister Subscription request - Error",  NSStringFromClass([UsersViewController class]));
    }];
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type {
    if ([payload.dictionaryPayload objectForKey:kVoipEvent] != nil) {
        __weak __typeof(self)weakSelf = self;
        UIApplication *application = [UIApplication sharedApplication];
        if ((application.applicationState == UIApplicationStateBackground)
            && _backgroundTask == UIBackgroundTaskInvalid) {
            _backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
                [application endBackgroundTask:weakSelf.backgroundTask];
                weakSelf.backgroundTask = UIBackgroundTaskInvalid;
            }];
        }
        if (![QBChat instance].isConnected) {
            [self connectToChat];
        }
        
    }
}

- (void)connectToChat {
    Profile *currentUser = [[Profile alloc] init];
    if (currentUser.isFull == false) {
        return;
    }
    __weak __typeof(self)weakSelf = self;
    
    [QBChat.instance connectWithUserID:currentUser.ID
                              password:DEFAULT_PASSOWORD
                            completion:^(NSError * _Nullable error) {
                                
                                __typeof(weakSelf)strongSelf = weakSelf;
                                
                                if (error) {
                                    if (error.code == QBResponseStatusCodeUnAuthorized) {
                                        [strongSelf logoutAction];
                                    } else {
                                        [SVProgressHUD showErrorWithStatus:NSLocalizedString(@"Please check your Internet connection", nil)];
                                        
                                    }
                                } else {
                                    [SVProgressHUD dismiss];
                                }
                            }];
}

@end
