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

NSString * const StatePending = @"PENDING";
NSString * const StateConnecting = @"CONNECTING";
NSString * const StateConnected = @"CONNECTED";
NSString * const StateDisconnected = @"DISCONNECTED";
NSString * const StateRejected = @"REJECTED";

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents
{
  return @[@"connectionDidConnect", @"connectionDidDisconnect", @"callRejected", @"deviceReady", @"deviceNotReady"];
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

    NSLog(@"CallKit Initialized");

    self.callKitCallController = [[CXCallController alloc] init];
  }
}

RCT_EXPORT_METHOD(connect: (NSDictionary *)params) {
  NSLog(@"Calling phone number %@", [params valueForKey:@"To"]);

//  [TwilioVoice setLogLevel:TVOLogLevelVerbose];

  UIDevice* device = [UIDevice currentDevice];
  device.proximityMonitoringEnabled = YES;

  if (self.call && self.call.state == TVOCallStateConnected) {
    self.userInitiatedDisconnect = YES;
    [self performEndCallActionWithUUID:self.call.uuid];
  } else {
    NSUUID *uuid = [NSUUID UUID];
    NSString *handle = [params valueForKey:@"To"];
    _callParams = [[NSMutableDictionary alloc] initWithDictionary:params];
    [self performStartCallActionWithUUID:uuid handle:handle];
  }
}

RCT_EXPORT_METHOD(disconnect) {
  NSLog(@"Disconnecting call");
  [self performEndCallActionWithUUID:self.call.uuid];
}

RCT_EXPORT_METHOD(setMuted: (BOOL *)muted) {
  NSLog(@"Mute/UnMute call");
  self.call.muted = muted;
}

RCT_EXPORT_METHOD(setSpeakerPhone: (BOOL *)speaker) {
  [self toggleAudioRoute:speaker];
}

RCT_EXPORT_METHOD(sendDigits: (NSString *)digits){
  if (self.call && self.call.state == TVOCallStateConnected) {
    NSLog(@"SendDigits %@", digits);
    [self.call sendDigits:digits];
  }
}

RCT_EXPORT_METHOD(unregister){
  NSLog(@"unregister");
  NSString *accessToken = [self fetchAccessToken];

  [TwilioVoice unregisterWithAccessToken:accessToken
                                              deviceToken:self.deviceTokenString
                                               completion:^(NSError * _Nullable error) {
                                                 if (error) {
                                                   NSLog(@"An error occurred while unregistering: %@", [error localizedDescription]);
                                                 } else {
                                                   NSLog(@"Successfully unregistered for VoIP push notifications.");
                                                 }
                                               }];

  self.deviceTokenString = nil;
}

RCT_EXPORT_METHOD(checkRecordPermission:(RCTResponseSenderBlock)callback) {
  AVAudioSessionRecordPermission permissionStatus = [[AVAudioSession sharedInstance] recordPermission];
  BOOL permissionGranted = permissionStatus == AVAudioSessionRecordPermissionGranted;
  NSLog(@"Record permission granted %@", permissionGranted ? @"true" : @"false");
  callback(@[[NSNull null], permissionGranted]);
}

RCT_REMAP_METHOD(requestRecordPermission,
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  [self checkRecordPermission:^(BOOL permissionGranted) {
    NSLog(@"Record permission granted %@", permissionGranted ? @"true" : @"false");
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
  NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
  if (self.callInvite) {
    if (self.callInvite.callSid){
      [params setObject:self.callInvite.callSid forKey:@"call_sid"];
    }
    if (self.callInvite.from){
      [params setObject:[self.callInvite.from fromValue] forKey:@"from"];
    }
    if (self.callInvite.to){
      [params setObject:self.callInvite.to forKey:@"to"];
    }
    /*
    if (self.callInvite.state == TVOCallInviteStatePending) {
      [params setObject:StatePending forKey:@"call_state"];
    } else if (self.callInvite.state == TVOCallInviteStateCanceled) {
      [params setObject:StateDisconnected forKey:@"call_state"];
    } else if (self.callInvite.state == TVOCallInviteStateRejected) {
      [params setObject:StateRejected forKey:@"call_state"];
    }*/
    resolve(params);
  } else if (self.call) {
    if (self.call.sid) {
      [params setObject:self.call.sid forKey:@"call_sid"];
    }
    if (self.call.to){
      [params setObject:self.call.to forKey:@"call_to"];
    }
    if (self.call.from){
      [params setObject:[self.call.from fromValue] forKey:@"call_from"];
    }
    if (self.call.state == TVOCallStateConnected) {
      [params setObject:StateConnected forKey:@"call_state"];
    } else if (self.call.state == TVOCallStateConnecting) {
      [params setObject:StateConnecting forKey:@"call_state"];
    } else if (self.call.state == TVOCallStateDisconnected) {
      [params setObject:StateDisconnected forKey:@"call_state"];
    }
    resolve(params);
  } else{
    reject(@"no_call", @"There was no active call", nil);
  }
}

- (void)initPushRegistry {
  self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
  self.voipRegistry.delegate = self;
  self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
  
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
    return accessToken;
  } else {
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
  NSLog(@"pushRegistry:didUpdatePushCredentials:forType");

  if ([type isEqualToString:PKPushTypeVoIP]) {
    const unsigned *tokenBytes = [credentials.token bytes];
    self.deviceTokenString = [NSString stringWithFormat:@"<%08x %08x %08x %08x %08x %08x %08x %08x>",
                              ntohl(tokenBytes[0]), ntohl(tokenBytes[1]), ntohl(tokenBytes[2]),
                              ntohl(tokenBytes[3]), ntohl(tokenBytes[4]), ntohl(tokenBytes[5]),
                              ntohl(tokenBytes[6]), ntohl(tokenBytes[7])];
    NSString *accessToken = [self fetchAccessToken];

    [TwilioVoice registerWithAccessToken:accessToken
                                              deviceToken:self.deviceTokenString
                                               completion:^(NSError *error) {
                                                 if (error) {
                                                   NSLog(@"An error occurred while registering: %@", [error localizedDescription]);
                                                   NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
                                                   [params setObject:[error localizedDescription] forKey:@"err"];

                                                   [self sendEventWithName:@"deviceNotReady" body:params];
                                                 } else {
                                                   NSLog(@"Successfully registered for VoIP push notifications.");
                                                   [self sendEventWithName:@"deviceReady" body:nil];
                                                 }
                                               }];
  }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
  NSLog(@"pushRegistry:didInvalidatePushTokenForType");

  if ([type isEqualToString:PKPushTypeVoIP]) {
    NSString *accessToken = [self fetchAccessToken];

    [TwilioVoice unregisterWithAccessToken:accessToken
                                                deviceToken:self.deviceTokenString
                                                 completion:^(NSError * _Nullable error) {
                                                   if (error) {
                                                     NSLog(@"An error occurred while unregistering: %@", [error localizedDescription]);
                                                   } else {
                                                     NSLog(@"Successfully unregistered for VoIP push notifications.");
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
  NSLog(@"pushRegistry:didReceiveIncomingPushWithPayload:forType:");
  if ([type isEqualToString:PKPushTypeVoIP]) {
      
    // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error` when delegate queue is not passed
    if (![TwilioVoice handleNotification:payload.dictionaryPayload delegate:self delegateQueue:nil]) {
      NSLog(@"This is not a valid Twilio Voice notification.");
    }
  }
}

/**
 * This delegate method is available on iOS 11 and above. Call the completion handler once the
 * notification payload is passed to the `TwilioVoice.handleNotification()` method.
 */
- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
  NSLog(@"pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:");

  // Save for later when the notification is properly handled.
  self.incomingPushCompletionCallback = completion;

  
  if ([type isEqualToString:PKPushTypeVoIP]) {
    // The Voice SDK will use main queue to invoke `cancelledCallInviteReceived:error` when delegate queue is not passed
    if (![TwilioVoice handleNotification:payload.dictionaryPayload delegate:self delegateQueue:nil]) {
      NSLog(@"This is not a valid Twilio Voice notification.");
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
- (void)callInviteReceived:(TVOCallInvite *)callInvite {
  /**
   * Calling `[TwilioVoice handleNotification:delegate:]` will synchronously process your notification payload and
   * provide you a `TVOCallInvite` object. Report the incoming call to CallKit upon receiving this callback.
   */

  NSLog(@"callInviteReceived:");

  if (self.callInvite) {
    NSLog(@"A CallInvite is already in progress. Ignoring the incoming CallInvite from %@", callInvite.from);
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
      [self incomingPushHandled];
    }
    return;
  } else if (self.call) {
    NSLog(@"Already an active call. Ignoring the incoming CallInvite from %@", callInvite.from);
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 13) {
      [self incomingPushHandled];
    }
    return;
  }

  self.callInvite = callInvite;

  NSString *from = nil;
  if (callInvite.from) {
    from = [callInvite.from fromValue];
  }
  [self reportIncomingCallFrom:from withUUID:callInvite.uuid];
}

- (void)cancelledCallInviteReceived:(TVOCancelledCallInvite *)cancelledCallInvite error:(NSError *)error {
    
  /**
   * The SDK may call `[TVONotificationDelegate callInviteReceived:error:]` asynchronously on the dispatch queue
   * with a `TVOCancelledCallInvite` if the caller hangs up or the client encounters any other error before the called
   * party could answer or reject the call.
   */

  NSLog(@"cancelledCallInviteReceived:");

  if (!self.callInvite ||
    ![self.callInvite.callSid isEqualToString:cancelledCallInvite.callSid]) {
    NSLog(@"No matching pending CallInvite. Ignoring the Cancelled CallInvite");
    return;
  }

  [self performEndCallActionWithUUID:self.callInvite.uuid];

  NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
  if (self.callInvite.callSid){
    [params setObject:self.callInvite.callSid forKey:@"call_sid"];
  }

  if (self.callInvite.from){
    [params setObject:[self.callInvite.from fromValue] forKey:@"from"];
  }
  if (self.callInvite.to){
    [params setObject:self.callInvite.to forKey:@"to"];
  }
  /*
  if (self.callInvite.state == TVOCallInviteStateCanceled) {
    [params setObject:StateDisconnected forKey:@"call_state"];
  } else if (self.callInvite.state == TVOCallInviteStateRejected) {
    [params setObject:StateRejected forKey:@"call_state"];
  }*/
  [self sendEventWithName:@"connectionDidDisconnect" body:params];
  
  self.callInvite = nil;
}

- (void)notificationError:(NSError *)error {
  NSLog(@"notificationError: %@", [error localizedDescription]);
}

#pragma mark - TVOCallDelegate
- (void)callDidStartRinging:(TVOCall *)call {
    NSLog(@"callDidStartRinging:");
}

- (void)callDidConnect:(TVOCall *)call {
  NSLog(@"callDidConnect:");
  
  self.call = call;
  self.callKitCompletionCallback(YES);
  self.callKitCompletionCallback = nil;
  
  [self toggleAudioRoute:YES];

  NSMutableDictionary *callParams = [[NSMutableDictionary alloc] init];
  [callParams setObject:call.sid forKey:@"call_sid"];
  if (call.state == TVOCallStateConnecting) {
    [callParams setObject:StateConnecting forKey:@"call_state"];
  } else if (call.state == TVOCallStateConnected) {
    [callParams setObject:StateConnected forKey:@"call_state"];
  }

  if (call.from){
    [callParams setObject:[call.from fromValue] forKey:@"from"];
  }
  if (call.to){
    [callParams setObject:call.to forKey:@"to"];
  }
  [self sendEventWithName:@"connectionDidConnect" body:callParams];
}

- (void)call:(TVOCall *)call isReconnectingWithError:(NSError *)error {
    NSLog(@"Call is reconnecting");
}

- (void)callDidReconnect:(TVOCall *)call {
    NSLog(@"Call reconnected");
}

- (void)call:(TVOCall *)call didFailToConnectWithError:(NSError *)error {
  NSLog(@"Call failed to connect: %@", error);

  self.callKitCompletionCallback(NO);
  [self performEndCallActionWithUUID:call.uuid];
  [self callDisconnected:error];
}

- (void)call:(TVOCall *)call didDisconnectWithError:(NSError *)error {
  if (error) {
    NSLog(@"Call failed: %@", error);
  } else {
    NSLog(@"Call disconnected");
  }

  if (!self.userInitiatedDisconnect) {
    CXCallEndedReason reason = CXCallEndedReasonRemoteEnded;
    if (error) {
      reason = CXCallEndedReasonFailed;
    }
    
    [self.callKitProvider reportCallWithUUID:call.uuid endedAtDate:[NSDate date] reason:reason];
  }
  
  [self callDisconnected:error];
}

- (void)callDisconnected:(NSError *)error {
  NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
  if (error) {
    NSString* errMsg = [error localizedDescription];
    if (error.localizedFailureReason) {
      errMsg = [error localizedFailureReason];
    }
    [params setObject:errMsg forKey:@"error"];
  }
  if (self.call.sid) {
    [params setObject:self.call.sid forKey:@"call_sid"];
  }
  if (self.call.to){
    [params setObject:self.call.to forKey:@"call_to"];
  }
  if (self.call.from){
    [params setObject:[self.call.from fromValue] forKey:@"call_from"];
  }
  if (self.call.state == TVOCallStateDisconnected) {
    [params setObject:StateDisconnected forKey:@"call_state"];
  }
  [self sendEventWithName:@"connectionDidDisconnect" body:params];

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
        NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
      }
    } else {
      if (![session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error]) {
        NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
      }
    }
  };
  self.audioDevice.block();
}

#pragma mark - CXProviderDelegate
- (void)providerDidReset:(CXProvider *)provider {
  NSLog(@"providerDidReset");
  self.audioDevice.enabled = YES;
}

- (void)providerDidBegin:(CXProvider *)provider {
  NSLog(@"providerDidBegin");
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
  NSLog(@"provider:didActivateAudioSession");
  self.audioDevice.enabled = YES;
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
  NSLog(@"provider:didDeactivateAudioSession");
  //TwilioVoice.audioEnabled = NO;
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action {
  NSLog(@"provider:timedOutPerformingAction");
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
  NSLog(@"provider:performStartCallAction");

  self.audioDevice.enabled = NO;
  self.audioDevice.block();

  [self.callKitProvider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:[NSDate date]];

  __weak typeof(self) weakSelf = self;
  [self performVoiceCallWithUUID:action.callUUID client:nil completion:^(BOOL success) {
    __strong typeof(self) strongSelf = weakSelf;
    if (success) {
      [strongSelf.callKitProvider reportOutgoingCallWithUUID:action.callUUID connectedAtDate:[NSDate date]];
      [action fulfill];
    } else {
      [action fail];
    }
  }];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
  NSLog(@"provider:performAnswerCallAction");

  // RCP: Workaround from https://forums.developer.apple.com/message/169511 suggests configuring audio in the
  //      completion block of the `reportNewIncomingCallWithUUID:update:completion:` method instead of in
  //      `provider:performAnswerCallAction:` per the WWDC examples.
  // [TwilioVoice configureAudioSession];

  NSAssert([self.callInvite.uuid isEqual:action.callUUID], @"We only support one Invite at a time.");

  self.audioDevice.enabled = NO;
  self.audioDevice.block();
  
  [self performAnswerVoiceCallWithUUID:action.callUUID completion:^(BOOL success) {
    if (success) {
      [action fulfill];
    } else {
      [action fail];
    }
  }];

  [action fulfill];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
  NSLog(@"provider:performEndCallAction");

  if (self.callInvite) {
    [self sendEventWithName:@"callRejected" body:@"callRejected"];
    [self.callInvite reject];
    self.callInvite = nil;
  } else if (self.call) {
    [self.call disconnect];
  }

  self.audioDevice.enabled = YES;
  [action fulfill];
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action {
  if (self.call && self.call.state == TVOCallStateConnected) {
    [self.call setOnHold:action.isOnHold];
    [action fulfill];
  } else {
    [action fail];
  }
}

#pragma mark - CallKit Actions
- (void)performStartCallActionWithUUID:(NSUUID *)uuid handle:(NSString *)handle {
  if (uuid == nil || handle == nil) {
    return;
  }

  CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:handle];
  CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:callHandle];
  CXTransaction *transaction = [[CXTransaction alloc] initWithAction:startCallAction];

  [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
    if (error) {
      NSLog(@"StartCallAction transaction request failed: %@", [error localizedDescription]);
    } else {
      NSLog(@"StartCallAction transaction request successful");

      CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
      callUpdate.remoteHandle = callHandle;
      callUpdate.supportsDTMF = YES;
      callUpdate.supportsHolding = YES;
      callUpdate.supportsGrouping = NO;
      callUpdate.supportsUngrouping = NO;
      callUpdate.hasVideo = NO;

      [self.callKitProvider reportCallWithUUID:uuid updated:callUpdate];
    }
  }];
}

- (void)reportIncomingCallFrom:(NSString *)from withUUID:(NSUUID *)uuid {
  CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:from];

  CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
  callUpdate.remoteHandle = callHandle;
  callUpdate.supportsDTMF = YES;
  callUpdate.supportsHolding = YES;
  callUpdate.supportsGrouping = NO;
  callUpdate.supportsUngrouping = NO;
  callUpdate.hasVideo = NO;

  [self.callKitProvider reportNewIncomingCallWithUUID:uuid update:callUpdate completion:^(NSError *error) {
    if (!error) {
      NSLog(@"Incoming call successfully reported");

      // RCP: Workaround per https://forums.developer.apple.com/message/169511
      // [TwilioVoice configureAudioSession];
    } else {
      NSLog(@"Failed to report incoming call successfully: %@.", [error localizedDescription]);
    }
  }];
}

- (void)performEndCallActionWithUUID:(NSUUID *)uuid {
  if (uuid == nil) {
    return;
  }

  UIDevice* device = [UIDevice currentDevice];
  device.proximityMonitoringEnabled = NO;

  CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
  CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];

  [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
    if (error) {
      NSLog(@"EndCallAction transaction request failed: %@", [error localizedDescription]);
    } else {
      NSLog(@"EndCallAction transaction request successful");
    }
  }];
}

- (void)performVoiceCallWithUUID:(NSUUID *)uuid
                          client:(NSString *)client
                      completion:(void(^)(BOOL success))completionHandler {

  __weak typeof(self) weakSelf = self;
  TVOConnectOptions *connectOptions = [TVOConnectOptions optionsWithAccessToken:[self fetchAccessToken] block:^(TVOConnectOptionsBuilder *builder) {
      __strong typeof(self) strongSelf = weakSelf;
    NSString *handle = [_callParams valueForKey:@"To"];
    builder.params = @{kTwimlParamTo: handle};
    builder.uuid = uuid;
  }];
  self.call = [TwilioVoice connectWithOptions:connectOptions delegate:self];
  self.callKitCompletionCallback = completionHandler;
}

- (void)performAnswerVoiceCallWithUUID:(NSUUID *)uuid
                            completion:(void(^)(BOOL success))completionHandler {
  __weak typeof(self) weakSelf = self;
  TVOAcceptOptions *acceptOptions = [TVOAcceptOptions optionsWithCallInvite:self.callInvite block:^(TVOAcceptOptionsBuilder *builder) {
    __strong typeof(self) strongSelf = weakSelf;
    builder.uuid = strongSelf.callInvite.uuid;
  }];

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
  NSLog(@"handleAppTerminateNotification called");

  if (self.call) {
    NSLog(@"handleAppTerminateNotification disconnecting an active call");
    [self.call disconnect];
  }
}

@end
