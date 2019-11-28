//
//  TwilioVoice.m
//
//  Created by Son Huynh on 11/19/19.
//  Copyright © 2019 Son Huynh. All rights reserved.
//

#import "RNTwilioVoice.h"
#import <React/RCTLog.h>

@import AVFoundation;
@import PushKit;
@import CallKit;
@import TwilioVoice;

@interface NSString (Additions)
- (NSString *)fromValue;
@end

@implementation NSString (Additions)
- (NSString *)fromValue {
  NSString *fromValue = nil;
  if (self) {
    fromValue = [self stringByReplacingOccurrencesOfString:@"client:" withString:@""];
  }
  return fromValue;
}
@end

@interface RNTwilioVoice () <PKPushRegistryDelegate, TVONotificationDelegate, TVOCallDelegate, CXProviderDelegate>
@property (nonatomic, strong) NSString *deviceTokenString;

@property (nonatomic, strong) PKPushRegistry *voipRegistry;
@property (nonatomic, strong) void(^incomingPushCompletionCallback)(void);
@property (nonatomic, strong) TVOCallInvite *callInvite;
@property (nonatomic, strong) TVOCall *call;
@property (nonatomic, strong) void(^callKitCompletionCallback)(BOOL);
@property (nonatomic, strong) TVODefaultAudioDevice *audioDevice;

@property (nonatomic, strong) CXProvider *callKitProvider;
@property (nonatomic, strong) CXCallController *callKitCallController;
@property (nonatomic, assign) BOOL userInitiatedDisconnect;
@end

@implementation RNTwilioVoice {
  NSMutableDictionary *_settings;
  NSMutableDictionary *_callParams;
  NSString *_tokenUrl;
  NSString *_token;
}

NSString *const kTwimlParamTo = @"to";

NSString * const StateConnecting = @"CONNECTING";
NSString * const StateConnected = @"CONNECTED";
NSString * const StateDisconnected = @"DISCONNECTED";
NSString * const StateReconnecting = @"RECONNECTING";
NSString * const StateRinging = @"RINGING";

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents
{
  return @[@"twilioVoiceDidRegister",
           @"twilioVoiceDidFailToRegister",
           @"twilioVoiceDidUnregister",
           @"callOutgoingStarted",
           @"callInviteReceived",
           @"callIncomingReceived",
           @"callIncomingAccepted",
           @"cancelledCallInviteReceived",
           @"callDidStartRinging",
           @"callDidConnect",
           @"callDidFailToConnect",
           @"callDidDisconnect",
           @"callReconnecting",
           @"callDidReconnect",
           @"callRejected"];
}

@synthesize bridge = _bridge;

- (void)dealloc {
  if (self.callKitProvider) {
    [self.callKitProvider invalidate];
  }

  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

RCT_EXPORT_METHOD(initWithAccessToken:(NSString *)token) {
  _token = token;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppTerminateNotification) name:UIApplicationWillTerminateNotification object:nil];
  [self initPushRegistry];
}

RCT_EXPORT_METHOD(initWithAccessTokenUrl:(NSString *)tokenUrl) {
  _tokenUrl = tokenUrl;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppTerminateNotification) name:UIApplicationWillTerminateNotification object:nil];
  [self initPushRegistry];
}

RCT_EXPORT_METHOD(configureCallKit: (NSDictionary *)params) {
  if (self.callKitCallController == nil) {
    _settings = [[NSMutableDictionary alloc] initWithDictionary:params];
    CXProviderConfiguration *configuration = [[CXProviderConfiguration alloc] initWithLocalizedName:params[@"appName"]];
    configuration.maximumCallGroups = 1;
    configuration.maximumCallsPerCallGroup = 1;
    if (_settings[@"imageName"]) {
      configuration.iconTemplateImageData = UIImagePNGRepresentation([UIImage imageNamed:_settings[@"imageName"]]);
    }
    if (_settings[@"ringtoneSound"]) {
      configuration.ringtoneSound = _settings[@"ringtoneSound"];
    }

    _callKitProvider = [[CXProvider alloc] initWithConfiguration:configuration];
    [_callKitProvider setDelegate:self queue:nil];

    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> configureCallKit: CallKit Initialized: %@", params);

    self.callKitCallController = [[CXCallController alloc] init];
  }
}

RCT_EXPORT_METHOD(connect: (NSDictionary *)params) {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 Caller: action -> connect: %@", params);

//  [TwilioVoice setLogLevel:TVOLogLevelVerbose];

  UIDevice* device = [UIDevice currentDevice];
  device.proximityMonitoringEnabled = YES;

  if (self.call && self.call.state == TVOCallStateConnected) {
    self.userInitiatedDisconnect = YES;
    [self performEndCallActionWithUUID:self.call.uuid];
  } else {
    NSUUID *uuid = [NSUUID UUID];
    NSString *handle = [params valueForKey:kTwimlParamTo];
    _callParams = [[NSMutableDictionary alloc] initWithDictionary:params];

    // Caller: perform start call manually
    [self performStartCallActionWithUUID:uuid handle:handle];
  }
}

RCT_EXPORT_METHOD(disconnect) {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 Caller/Receiver: action -> disconnect");
  // Caller: perform end call on: didFailToConnectWithError, disconnect call manually
  // Receiver: perform end call on: didFailToConnectWithError, cancelledCallInviteReceived
  [self performEndCallActionWithUUID:self.call.uuid];
}

RCT_EXPORT_METHOD(setMuted: (BOOL *)muted) {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> setMuted");
  self.call.muted = muted;
}

RCT_EXPORT_METHOD(setSpeakerPhone: (BOOL *)speaker) {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> setSpeakerPhone");
  [self toggleAudioRoute:speaker];
}

RCT_EXPORT_METHOD(sendDigits: (NSString *)digits){
  if (self.call && self.call.state == TVOCallStateConnected) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> sendDigits: %@", digits);
    [self.call sendDigits:digits];
  }
}

RCT_EXPORT_METHOD(unregister){
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> unregister");
  NSString *accessToken = [self fetchAccessToken];

  __weak typeof(self) weakSelf = self;
  [TwilioVoice unregisterWithAccessToken:accessToken
                             deviceToken:self.deviceTokenString
                              completion:^(NSError * _Nullable error) {
    if (error) {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 An error occurred while unregistering: %@", [error localizedDescription]);
    } else {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Successfully unregistered for VoIP push notifications.");
      [weakSelf sendEventWithName:@"twilioVoiceDidUnregister" body:nil];
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 event -> twilioVoiceDidUnregister");
    }
  }];

  self.deviceTokenString = nil;
}

RCT_EXPORT_METHOD(getRecordPermission:(RCTResponseSenderBlock)callback) {
  AVAudioSessionRecordPermission permissionStatus = [[AVAudioSession sharedInstance] recordPermission];
  BOOL permissionGranted = permissionStatus == AVAudioSessionRecordPermissionGranted;
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> getRecordPermission: granted %@", permissionGranted ? @"true" : @"false");
  callback(@[[NSNull null], @(permissionGranted)]);
}

RCT_REMAP_METHOD(requestRecordPermission,
                 requestRecordPermissionWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  [self checkRecordPermission:^(BOOL permissionGranted) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> requestRecordPermission: granted %@", permissionGranted ? @"true" : @"false");
    if (permissionGranted) {
      resolve(nil);
    } else {
      reject(@"no_permission", @"Record permission is not granted", nil);
    }
  }];
}

RCT_REMAP_METHOD(getActiveCall,
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> getActiveCall");
  NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
  if (self.call) {
    NSMutableDictionary *params = [self callParamsFor:self.call];
    resolve(params);
  } else{
    reject(@"no_call", @"There was no active call", nil);
  }
}

- (NSString *)callStateFor:(TVOCall *)call {
  if (call.state == TVOCallStateConnected) {
    return StateConnected;
  } else if (call.state == TVOCallStateConnecting) {
    return StateConnecting;
  } else if (call.state == TVOCallStateDisconnected) {
    return StateDisconnected;
  } else if (call.state == TVOCallStateReconnecting) {
    return StateReconnecting;
  } else if (call.state == TVOCallStateRinging) {
    return StateRinging;
  }
  return @"INVALID";
}

- (NSMutableDictionary *)callInviteParamsFor:(TVOCallInvite *)callInvite {
  NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
  if (callInvite.callSid) {
    [params setObject:callInvite.callSid forKey:@"sid"];
  }
  if (callInvite.to){
    [params setObject:callInvite.to forKey:@"to"];
  }
  if (callInvite.from){
    [params setObject:[callInvite.from fromValue] forKey:@"from"];
  }
  return params;
}

- (NSMutableDictionary *)callParamsFor:(TVOCall *)call {
  NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
  if (call.sid) {
    [params setObject:call.sid forKey:@"sid"];
  }
  if (call.to){
    [params setObject:call.to forKey:@"to"];
  }
  if (call.from){
    [params setObject:[call.from fromValue] forKey:@"from"];
  }
  [params setObject:[self callStateFor:call] forKey:@"state"];
  return params;
}

- (NSMutableDictionary *)paramsForError:(NSError *)error {
  NSMutableDictionary *params = [self callParamsFor:self.call];
  if (error) {
    NSMutableDictionary *errorParams = [[NSMutableDictionary alloc] init];
    if (error.code) {
      [errorParams setObject:[@([error code]) stringValue] forKey:@"code"];
    }
    if (error.domain) {
      [errorParams setObject:[error domain] forKey:@"domain"];
    }
    if (error.localizedDescription) {
      [errorParams setObject:[error localizedDescription] forKey:@"message"];
    }
    if (error.localizedFailureReason) {
      [errorParams setObject:[error localizedFailureReason] forKey:@"reason"];
    }
    [params setObject:errorParams forKey:@"error"];
  }
  return params;
}

- (void)initPushRegistry {
  self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
  self.voipRegistry.delegate = self;
  self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👇 action -> initPushRegistry: PushRegistry Initialized");
    
  /*
   * The important thing to remember when providing a TVOAudioDevice is that the device must be set
   * before performing any other actions with the SDK (such as connecting a Call, or accepting an incoming Call).
   * In this case we've already initialized our own `TVODefaultAudioDevice` instance which we will now set.
   */
  self.audioDevice = [TVODefaultAudioDevice audioDevice];
  TwilioVoice.audioDevice = self.audioDevice;
}

- (NSString *)fetchAccessToken {
  if (_tokenUrl) {
    NSString *accessToken = [NSString stringWithContentsOfURL:[NSURL URLWithString:_tokenUrl]
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 AccessToken: %@", accessToken);
    return accessToken;
  } else {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 AccessToken: %@", _token);
    return _token;
  }
}

- (void)checkRecordPermission:(void(^)(BOOL permissionGranted))completion {
  AVAudioSessionRecordPermission permissionStatus = [[AVAudioSession sharedInstance] recordPermission];
  switch (permissionStatus) {
    case AVAudioSessionRecordPermissionGranted:
      // Record permission already granted.
      completion(YES);
      break;
    case AVAudioSessionRecordPermissionDenied:
      // Record permission denied.
      completion(NO);
      break;
    case AVAudioSessionRecordPermissionUndetermined:
    {
      // Requesting record permission.
      // Optional: pop up app dialog to let the users know if they want to request.
      [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        completion(granted);
      }];
      break;
    }
    default:
      completion(NO);
      break;
  }
}

#pragma mark - PKPushRegistryDelegate
- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 pushRegistry:didUpdatePushCredentials:forType");

  if ([type isEqualToString:PKPushTypeVoIP]) {
    const unsigned *tokenBytes = [credentials.token bytes];
    self.deviceTokenString = [NSString stringWithFormat:@"<%08x %08x %08x %08x %08x %08x %08x %08x>",
                              ntohl(tokenBytes[0]), ntohl(tokenBytes[1]), ntohl(tokenBytes[2]),
                              ntohl(tokenBytes[3]), ntohl(tokenBytes[4]), ntohl(tokenBytes[5]),
                              ntohl(tokenBytes[6]), ntohl(tokenBytes[7])];
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 DeviceToken: %@", self.deviceTokenString);
    NSString *accessToken = [self fetchAccessToken];

    __weak typeof(self) weakSelf = self;
    [TwilioVoice registerWithAccessToken:accessToken
                             deviceToken:self.deviceTokenString
                              completion:^(NSError *error) {
     if (error) {
       NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 An error occurred while registering: %@", [error localizedDescription]);
       NSMutableDictionary *params = [weakSelf paramsForError:error];
       [weakSelf sendEventWithName:@"twilioVoiceDidFailToRegister" body:params];
       NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 event -> twilioVoiceDidFailToRegister: %@", params);
     } else {
       NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Successfully registered for VoIP push notifications.");
       [weakSelf sendEventWithName:@"twilioVoiceDidRegister" body:nil];
       NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 event -> twilioVoiceDidRegister");
     }
   }];
  }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 pushRegistry:didInvalidatePushTokenForType");

  if ([type isEqualToString:PKPushTypeVoIP]) {
    NSString *accessToken = [self fetchAccessToken];

    __weak typeof(self) weakSelf = self;
    [TwilioVoice unregisterWithAccessToken:accessToken
                               deviceToken:self.deviceTokenString
                                completion:^(NSError * _Nullable error) {
      if (error) {
        NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 An error occurred while unregistering: %@", [error localizedDescription]);
      } else {
        NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Successfully unregistered for VoIP push notifications.");
        [weakSelf sendEventWithName:@"twilioVoiceDidUnregister" body:nil];
        NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 event -> twilioVoiceDidUnregister");
      }
    }];

    self.deviceTokenString = nil;
  }
}

/**
 * Try using the `pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:` method if
 * your application is targeting iOS 11. According to the docs, this delegate method is deprecated by Apple.
 */
- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(NSString *)type {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 pushRegistry:didReceiveIncomingPushWithPayload:forType:");
  if ([type isEqualToString:PKPushTypeVoIP]) {
      
    // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error` when delegate queue is not passed
    if (![TwilioVoice handleNotification:payload.dictionaryPayload delegate:self delegateQueue:nil]) {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 This is not a valid Twilio Voice notification.");
    }
  }
}

/**
 * This delegate method is available on iOS 11 and above. Call the completion handler once the
 * notification payload is passed to the `TwilioVoice.handleNotification()` method.
 */
- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:");

  // Save for later when the notification is properly handled.
  // self.incomingPushCompletionCallback = completion;

  
  if ([type isEqualToString:PKPushTypeVoIP]) {
    // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error` when delegate queue is not passed
    if (![TwilioVoice handleNotification:payload.dictionaryPayload delegate:self delegateQueue:nil]) {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 This is not a valid Twilio Voice notification.");
    }
  }
  if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
    // Save for later when the notification is properly handled.
    self.incomingPushCompletionCallback = completion;
  } else {
    /**
    * The Voice SDK processes the call notification and returns the call invite synchronously. Report the incoming call to
    * CallKit and fulfill the completion before exiting this callback method.
    */
    completion();
  }
}

- (void)incomingPushHandled {
  if (self.incomingPushCompletionCallback) {
    self.incomingPushCompletionCallback();
    self.incomingPushCompletionCallback = nil;
  }
}

#pragma mark - TVONotificationDelegate
// Receiver: Notifies the delegate that a Call Invite was received.
- (void)callInviteReceived:(TVOCallInvite *)callInvite {
  /**
   * Calling `[TwilioVoice handleNotification:delegate:]` will synchronously process your notification payload and
   * provide you a `TVOCallInvite` object. Report the incoming call to CallKit upon receiving this callback.
   */

  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: callInviteReceived");

  if (self.callInvite) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: A CallInvite is already in progress. Ignoring the incoming CallInvite from %@", callInvite.from);
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
      [self incomingPushHandled];
    }
    return;
  } else if (self.call) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: Already an active call. Ignoring the incoming CallInvite from %@", callInvite.from);
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
      [self incomingPushHandled];
    }
    return;
  }

  self.callInvite = callInvite;

  NSMutableDictionary *params = [self callInviteParamsFor:callInvite];
  [self sendEventWithName:@"callInviteReceived" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Receiver: event -> callInviteReceived: %@", params);
  
  // Receiver: report imcoming call on: callInviteReceived
  [self reportIncomingCallFrom:callInvite];
}

// Receiver: Notifies the delegate that a Cancelled Call Invite was received.
- (void)cancelledCallInviteReceived:(TVOCancelledCallInvite *)cancelledCallInvite error:(NSError *)error {
    
  /**
   * The SDK may call `[TVONotificationDelegate callInviteReceived:error:]` asynchronously on the dispatch queue
   * with a `TVOCancelledCallInvite` if the caller hangs up or the client encounters any other error before the called
   * party could answer or reject the call.
   */

  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: cancelledCallInviteReceived");

  if (!self.callInvite ||
    ![self.callInvite.callSid isEqualToString:cancelledCallInvite.callSid]) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: No matching pending CallInvite. Ignoring the Cancelled CallInvite");
    return;
  }

  NSMutableDictionary *params = [self callInviteParamsFor:self.callInvite];
  [self sendEventWithName:@"cancelledCallInviteReceived" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Receiver: event -> cancelledCallInviteReceived: %@", params);

  // Caller: perform end call on: didFailToConnectWithError, disconnect call manually
  // Receiver: perform end call on: didFailToConnectWithError, cancelledCallInviteReceived
  [self performEndCallActionWithUUID:self.callInvite.uuid];
  self.callInvite = nil;
}

- (void)notificationError:(NSError *)error {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 notificationError: %@", [error localizedDescription]);
}

#pragma mark - TVOCallDelegate
// Caller: Notifies the delegate that the called party is being alerted of a Call.
- (void)callDidStartRinging:(TVOCall *)call {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller: callDidStartRinging");
  
  self.call = call;

  NSMutableDictionary *params = [self callParamsFor:call];
  [self sendEventWithName:@"callDidStartRinging" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Caller: event -> callDidStartRinging: %@", params);
}

// Caller/Receiver: Notifies the delegate that a Call has connected.
- (void)callDidConnect:(TVOCall *)call {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: callDidConnect");
  
  self.call = call;
  self.callKitCompletionCallback(YES);
  self.callKitCompletionCallback = nil;
  
  [self toggleAudioRoute:YES];

  NSMutableDictionary *params = [self callParamsFor:call];
  [self sendEventWithName:@"callDidConnect" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Caller/Receiver: event -> callDidConnect: %@", params);
}

// Caller/Receiver: Notifies the delegate that a Call starts to reconnect due to network change event.
/* Reconnect is triggered when a network change is detected and Call is already in `TVOCallStateConnected` state.
 * If the call is either in `TVOCallStateConnecting` or in `TVOCallStateRinging` when network change happened
 * then the current call will disconnect.
 */
- (void)call:(TVOCall *)call isReconnectingWithError:(NSError *)error {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: call isReconnectingWithError: %@", error);

  self.call = call;

  NSMutableDictionary *params = [self paramsForError:error];
  [self sendEventWithName:@"callReconnecting" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Caller/Receiver: event -> callReconnecting: %@", params);
}

// Caller/Receiver: Notifies the delegate that a Call is reconnected.
- (void)callDidReconnect:(TVOCall *)call {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: callDidReconnect");

  self.call = call;

  NSMutableDictionary *params = [self callParamsFor:call];
  [self sendEventWithName:@"callDidReconnect" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Caller/Receiver: event -> callDidReconnect: %@", params);
}

// Caller/Receiver: Notifies the delegate that a Call has failed to connect/accept.
- (void)call:(TVOCall *)call didFailToConnectWithError:(NSError *)error {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: call didFailToConnectWithError: %@", error);

  self.call = call;
  self.callKitCompletionCallback(NO);

  NSMutableDictionary *params = [self paramsForError:error];
  [self sendEventWithName:@"callDidFailToConnect" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Caller/Receiver: event -> callDidFailToConnect: %@", params);

  // Caller: perform end call on: didFailToConnectWithError, disconnect call manually
  // Receiver: perform end call on: didFailToConnectWithError, cancelledCallInviteReceived
  [self performEndCallActionWithUUID:call.uuid];
  [self callDisconnected];
}

// Caller/Receiver: Notifies the delegate that a Call has disconnected.
- (void)call:(TVOCall *)call didDisconnectWithError:(NSError *)error {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: call didDisconnectWithError: %@", error);

  self.call = call;

  NSMutableDictionary *params = [self paramsForError:error];
  [self sendEventWithName:@"callDidDisconnect" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Caller/Receiver: event -> callDidDisconnect: %@", params);

  // Receiver:
  if (!self.userInitiatedDisconnect) {
    CXCallEndedReason reason = CXCallEndedReasonRemoteEnded;
    if (error) {
      reason = CXCallEndedReasonFailed;
    }
    
    // Receiver: report call ended at ...
    [self.callKitProvider reportCallWithUUID:call.uuid endedAtDate:[NSDate date] reason:reason];
  }

  [self callDisconnected];
}

- (void)callDisconnected {
  self.call = nil;
  self.callKitCompletionCallback = nil;
  self.userInitiatedDisconnect = NO;
}

#pragma mark - AVAudioSession
- (void)toggleAudioRoute: (BOOL *)toSpeaker {
  // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver. Use port override to switch the route.
  self.audioDevice.block =  ^ {
    // We will execute `kDefaultAVAudioSessionConfigurationBlock` first.
    kTVODefaultAVAudioSessionConfigurationBlock();
    
    // Overwrite the audio route
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (toSpeaker) {
      if (![session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error]) {
        NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Unable to reroute audio: %@", [error localizedDescription]);
      }
    } else {
      if (![session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error]) {
        NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Unable to reroute audio: %@", [error localizedDescription]);
      }
    }
  };
  self.audioDevice.block();
}

#pragma mark - CXProviderDelegate
- (void)providerDidReset:(CXProvider *)provider {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 providerDidReset");
  self.audioDevice.enabled = YES;
}

- (void)providerDidBegin:(CXProvider *)provider {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 providerDidBegin");
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 provider:didActivateAudioSession");
  self.audioDevice.enabled = YES;
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 provider:didDeactivateAudioSession");
  //self.audioDevice.enabled = NO;
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 provider:timedOutPerformingAction");
}

// Caller: Called when the provider performs the specified start call action.
// Caller: Called after perform start call manually
- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller: provider:performStartCallAction");

  self.audioDevice.enabled = NO;
  self.audioDevice.block();

  // Caller: report outgoing call start connecting at ...
  [self.callKitProvider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:[NSDate date]];

  // Caller: Make an outgoing Call after: perform start call manually
  __weak typeof(self) weakSelf = self;
  [self performVoiceCallWithUUID:action.callUUID client:nil completion:^(BOOL success) {
    __strong typeof(self) strongSelf = weakSelf;
    if (success) {
      // Caller: report outgoing call connected at ...
      [strongSelf.callKitProvider reportOutgoingCallWithUUID:action.callUUID connectedAtDate:[NSDate date]];
      [action fulfill];
    } else {
      [action fail];
    }
  }];
}

// Receiver: Called when the provider performs the specified answer call action.
// Receiver: Called after accepts the incoming Call Invite via CallKit.
- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: provider:performAnswerCallAction");

  // RCP: Workaround from https://forums.developer.apple.com/message/169511 suggests configuring audio in the
  //      completion block of the `reportNewIncomingCallWithUUID:update:completion:` method instead of in
  //      `provider:performAnswerCallAction:` per the WWDC examples.
  // [TwilioVoice configureAudioSession];

  NSAssert([self.callInvite.uuid isEqual:action.callUUID], @"We only support one Invite at a time.");

  self.audioDevice.enabled = NO;
  self.audioDevice.block();

  // Receiver: Accepts the incoming Call Invite.
  [self performAnswerVoiceCallWithUUID:action.callUUID completion:^(BOOL success) {
    if (success) {
      [action fulfill];
    } else {
      [action fail];
    }
  }];

  [action fulfill];
}

// Called when the provider performs the specified end call action.
// Called after: perform end call
// Caller: perform end call on: didFailToConnectWithError, disconnect call manually
// Receiver: perform end call on: didFailToConnectWithError, cancelledCallInviteReceived
- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: provider:performEndCallAction");

  if (self.callInvite) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: Rejects the incoming Call Invite");
    [self sendEventWithName:@"callRejected" body:@"callRejected"];
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Receiver: event -> callRejected");
    // Receiver: Rejects the incoming Call Invite: via CallKit
    [self.callInvite reject];
    self.callInvite = nil;
  } else if (self.call) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: Disconnects the Call");
    // Caller/Receiver: Disconnects the Call on: disconnect call manually or via CallKit
    [self.call disconnect];
  }

  self.audioDevice.enabled = YES;
  [action fulfill];
}

// Called when the provider performs the specified set held call action.
- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action {
  if (self.call && self.call.state == TVOCallStateConnected) {
    [self.call setOnHold:action.isOnHold];
    [action fulfill];
  } else {
    [action fail];
  }
}

#pragma mark - CallKit Actions
// Caller: perform start call manually
- (void)performStartCallActionWithUUID:(NSUUID *)uuid handle:(NSString *)handle {
  if (uuid == nil || handle == nil) {
    return;
  }
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller: performStartCallActionWithUUID");

  CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:handle];
  CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:callHandle];
  CXTransaction *transaction = [[CXTransaction alloc] initWithAction:startCallAction];

  __weak typeof(self) weakSelf = self;
  [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
    __strong typeof(self) strongSelf = weakSelf;
    if (error) {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller: StartCallAction transaction request failed: %@", [error localizedDescription]);
    } else {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller: StartCallAction transaction request successful");

      CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
      callUpdate.remoteHandle = callHandle;
      callUpdate.supportsDTMF = YES;
      callUpdate.supportsHolding = YES;
      callUpdate.supportsGrouping = NO;
      callUpdate.supportsUngrouping = NO;
      callUpdate.hasVideo = NO;

      [strongSelf.callKitProvider reportCallWithUUID:uuid updated:callUpdate];
    }
  }];
}

// Receiver: report imcoming call on: callInviteReceived
- (void)reportIncomingCallFrom:(TVOCallInvite *)callInvite {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: reportIncomingCallFrom");

  NSString *from = nil;
  if (callInvite.from) {
    from = [callInvite.from fromValue];
  }

  CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:from];

  CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
  callUpdate.remoteHandle = callHandle;
  callUpdate.supportsDTMF = YES;
  callUpdate.supportsHolding = YES;
  callUpdate.supportsGrouping = NO;
  callUpdate.supportsUngrouping = NO;
  callUpdate.hasVideo = NO;

  __weak typeof(self) weakSelf = self;
  [self.callKitProvider reportNewIncomingCallWithUUID:callInvite.uuid update:callUpdate completion:^(NSError *error) {
    __strong typeof(self) strongSelf = weakSelf;
    if (!error) {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: Incoming call successfully reported");

      NSMutableDictionary *params = [strongSelf callInviteParamsFor:callInvite];
      [strongSelf sendEventWithName:@"callIncomingReceived" body:params];
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Receiver: event -> callIncomingReceived: %@", params);

      // RCP: Workaround per https://forums.developer.apple.com/message/169511
      // [TwilioVoice configureAudioSession];
    } else {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: Failed to report incoming call successfully: %@.", [error localizedDescription]);
      // An incoming call may be disallowed by the system if, 
      // for example, the caller handle is blocked, or the user has Do Not Disturb enabled.
    }
  }];
}

// Caller: perform end call on: didFailToConnectWithError, disconnect call manually
// Receiver: perform end call on: didFailToConnectWithError, cancelledCallInviteReceived
- (void)performEndCallActionWithUUID:(NSUUID *)uuid {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: performEndCallActionWithUUID");
  
  UIDevice* device = [UIDevice currentDevice];
  device.proximityMonitoringEnabled = NO;

  CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
  CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];

  [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
    if (error) {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: EndCallAction transaction request failed: %@", [error localizedDescription]);
    } else {
      NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller/Receiver: EndCallAction transaction request successful");
    }
  }];
}

// Caller: Make an outgoing Call after: perform start call manually
- (void)performVoiceCallWithUUID:(NSUUID *)uuid
                          client:(NSString *)client
                      completion:(void(^)(BOOL success))completionHandler {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Caller: Make an outgoing Call / performVoiceCallWithUUID");

  TVOConnectOptions *connectOptions = [TVOConnectOptions optionsWithAccessToken:[self fetchAccessToken] block:^(TVOConnectOptionsBuilder *builder) {
    NSString *handle = [_callParams valueForKey:kTwimlParamTo];
    builder.params = @{kTwimlParamTo: handle};
    builder.uuid = uuid;
  }];

  // Make an outgoing Call.
  // If connect fails, `call:didFailToConnectWithError` or `call:didDisconnectWithError` callback is raised with an `NSError` object.
  self.call = [TwilioVoice connectWithOptions:connectOptions delegate:self];
  self.callKitCompletionCallback = completionHandler;

  NSMutableDictionary *params = [self callParamsFor:self.call];
  [self sendEventWithName:@"callOutgoingStarted" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Receiver: event -> callOutgoingStarted: %@", params);
}

// Receiver: Accepts the incoming Call Invite.
- (void)performAnswerVoiceCallWithUUID:(NSUUID *)uuid
                            completion:(void(^)(BOOL success))completionHandler {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 Receiver: Accepts the incoming Call Invite / performAnswerVoiceCallWithUUID");
  
  NSMutableDictionary *params = [self callInviteParamsFor:self.callInvite];
  [self sendEventWithName:@"callIncomingAccepted" body:params];
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👆 Receiver: event -> callIncomingAccepted: %@", params);

  __weak typeof(self) weakSelf = self;
  TVOAcceptOptions *acceptOptions = [TVOAcceptOptions optionsWithCallInvite:self.callInvite block:^(TVOAcceptOptionsBuilder *builder) {
    __strong typeof(self) strongSelf = weakSelf;
    builder.uuid = strongSelf.callInvite.uuid; // replace with uuid param?
  }];

  // Accepts the incoming Call Invite.
  // If accept fails, `call:didFailToConnectWithError:` or `call:didDisconnectWithError:` callback is raised with an `NSError` object.
  self.call = [self.callInvite acceptWithOptions:acceptOptions delegate:self];

  if (!self.call) {
    completionHandler(NO);
  } else {
    self.callKitCompletionCallback = completionHandler;
  }
  
  self.callInvite = nil;
  
  if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
    [self incomingPushHandled];
  }
}

- (void)handleAppTerminateNotification {
  NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 handleAppTerminateNotification called");

  if (self.call) {
    NSLog(@"\n\n\n☎️ RNTwilioVoice ☎️ 👉 handleAppTerminateNotification disconnecting an active call");
    [self.call disconnect];
  }
}

@end
