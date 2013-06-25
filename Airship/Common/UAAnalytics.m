/*
 Copyright 2009-2011 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>

#import "UAAnalytics+Internal.h"

#import "UA_SBJSON.h"
#import "UA_Reachability.h"

#import "UAirship.h"
#import "UAUtils.h"
#import "UAAnalyticsDBManager.h"
#import "UAEvent.h"
#import "UALocationEvent.h"
#import "UAUser.h"
#import "UAConfig.h"
#import "UAHTTPConnectionOperation.h"
#import "UADelayOperation.h"

typedef void (^UAAnalyticsUploadCompletionBlock)(void);

// NOTE: Setup a background task in the appDidBackground method, then use
// that background identifier for should send background logic


@implementation UAAnalytics

@synthesize session;
@synthesize notificationUserInfo = notificationUserInfo_;
@synthesize databaseSize = databaseSize_;
@synthesize x_ua_max_total;
@synthesize x_ua_max_batch;
@synthesize x_ua_max_wait;
@synthesize x_ua_min_batch_interval;
@synthesize sendInterval = sendInterval_;
@synthesize oldestEventTime;
@synthesize sendBackgroundTask = sendBackgroundTask_;

// Testing properties
@synthesize isEnteringForeground = isEnteringForeground_;

#pragma mark -
#pragma mark Object Lifecycle

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    RELEASE_SAFELY(notificationUserInfo_);
    RELEASE_SAFELY(session);
    RELEASE_SAFELY(lastLocationSendTime);
    self.config = nil;
    [self.queue cancelAllOperations];
    self.queue = nil;
    [super dealloc];
}

- (id)initWithConfig:(UAConfig *)airshipConfig {
    if (self = [super init]) {
        //set server to default if not specified in options
        self.config = airshipConfig;
        
        [self resetEventsDatabaseStatus];
        
        x_ua_max_total = X_UA_MAX_TOTAL;
        x_ua_max_batch = X_UA_MAX_BATCH;
        x_ua_max_wait = X_UA_MAX_WAIT;
        x_ua_min_batch_interval = X_UA_MIN_BATCH_INTERVAL;
        
        // Set out starting interval to the X_UA_MIN_BATCH_INTERVAL as the default value
        sendInterval_ = X_UA_MIN_BATCH_INTERVAL;
        
        [self restoreFromDefault];
        [self saveDefault];//save defaults to store lastSendTime if this was an initial condition
        
        // Register for interface-change notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(refreshSessionWhenNetworkChanged)
                                                     name:kUA_ReachabilityChangedNotification
                                                   object:nil];
        
        // Register for background notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        // Register for foreground notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(enterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
        // App inactive/active for incoming calls, notification center, and taskbar 
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(willResignActive)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        
        /*
         * This is the Build field in Xcode. If it's not set, use a blank string.
         */
        packageVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:(id)kCFBundleVersionKey];
        if (packageVersion == nil) {
            packageVersion = @"";
        }
        
        [self initSession];
        sendBackgroundTask_ = UIBackgroundTaskInvalid;

        self.queue = [[[NSOperationQueue alloc] init] autorelease];
        self.queue.maxConcurrentOperationCount = 1;

        //call send after waiting for the first batch upload interval
        UADelayOperation *delayOperation = [UADelayOperation operationWithDelayInSeconds:UAAnalyticsFirstBatchUploadInterval];
        delayOperation.completionBlock = ^{
            [self send];
        };

        [self.queue addOperation:delayOperation];

        // TODO: add a one time perform selector after delay for init analytics on cold start (app_open)
    }
    return self;
}

- (void)initSession {
    session = [[NSMutableDictionary alloc] init];
    [self refreshSessionWhenNetworkChanged];
    [self refreshSessionWhenActive];
}

#pragma mark -
#pragma mark Network Changes

- (void)refreshSessionWhenNetworkChanged {
    
    // Capture connection type using Reachability
    NetworkStatus netStatus = [[Reachability reachabilityForInternetConnection] currentReachabilityStatus];
    NSString *connectionTypeString = @"";
    switch (netStatus) {
        case UA_NotReachable:
        {
            connectionTypeString = @"none";//this should never be sent
            break;
        }    
        case UA_ReachableViaWWAN:
        {
            connectionTypeString = @"cell";
            break;
        }            
        case UA_ReachableViaWiFi:
        {
            connectionTypeString = @"wifi";
            break;
        }
    }    
    [session setValue:connectionTypeString forKey:@"connection_type"];
}

- (void)refreshSessionWhenActive {
    
    // marking the beginning of a new session
    [session setObject:[UAUtils UUID] forKey:@"session_id"];
    
    // setup session with push id
    BOOL launchedFromPush = notificationUserInfo_ != nil;
    
    NSString *pushId = [notificationUserInfo_ objectForKey:@"_"];
    
    // set launched-from-push session values for both push and rich push
    if (pushId != nil) {
        [session setValue:pushId forKey:@"launched_from_push_id"];
    } else if (launchedFromPush) {
        //if the server did not send a push ID (likely because the payload did not have room)
        //generate an ID for the server to use
        [session setValue:[UAUtils UUID] forKey:@"launched_from_push_id"];
    } else {
        [session removeObjectForKey:@"launched_from_push_id"];
    }
    
    // Get the rich push ID, which can be sent as a one-element array or a string
    NSString *richPushId = nil;
    NSObject *richPushValue = [notificationUserInfo_ objectForKey:@"_uamid"];
    if ([richPushValue isKindOfClass:[NSArray class]]) {
        NSArray *richPushIds = (NSArray *)richPushValue;
        if (richPushIds.count > 0) {
            richPushId = [richPushIds objectAtIndex:0];
        }
    } else if ([richPushValue isKindOfClass:[NSString class]]) {
        richPushId = (NSString *)richPushValue;
    }
    
    if (richPushId != nil) {
        [session setValue:richPushId forKey:@"launched_from_rich_push_id"];
    }
    
    self.notificationUserInfo = nil;
    
    // check enabled notification types
    NSMutableArray *notification_types = [NSMutableArray array];
    UIRemoteNotificationType enabledRemoteNotificationTypes = [[UIApplication sharedApplication] enabledRemoteNotificationTypes];
    
    if ((UIRemoteNotificationTypeBadge & enabledRemoteNotificationTypes) > 0) {
        [notification_types addObject:@"badge"];
    }
    
    if ((UIRemoteNotificationTypeSound & enabledRemoteNotificationTypes) > 0) {
        [notification_types addObject:@"sound"];
    }
    
    if ((UIRemoteNotificationTypeAlert & enabledRemoteNotificationTypes) > 0) {
        [notification_types addObject:@"alert"];
    }

    if ((UIRemoteNotificationTypeNewsstandContentAvailability & enabledRemoteNotificationTypes) > 0) {
        [notification_types addObject:@"newsstand"];
    }
    
    [session setObject:notification_types forKey:@"notification_types"];
    
    NSTimeZone *localtz = [NSTimeZone defaultTimeZone];
    [session setObject:[NSNumber numberWithDouble:[localtz secondsFromGMT]] forKey:@"time_zone"];
    [session setObject:([localtz isDaylightSavingTime] ? @"true" : @"false") forKey:@"daylight_savings"];
    
    [session setObject:[[UIDevice currentDevice] systemVersion] forKey:@"os_version"];
    [session setObject:[UAirshipVersion get] forKey:@"lib_version"];
    [session setValue:packageVersion forKey:@"package_version"];
    
    // ensure that the app is foregrounded (necessary for Newsstand background invocation
    BOOL isInForeground = ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground);
    [session setObject:(isInForeground ? @"true" : @"false") forKey:@"foreground"];
}

#pragma mark -
#pragma mark Application State

- (void)enterForeground {
    UA_LTRACE(@"Enter Foreground.");

    [self invalidateBackgroundTask];
    // do not send the foreground event yet, as we are not actually in the foreground
    // (we are merely in the process of foregorunding)
    // set this flag so that the even will be sent as soon as the app is active.
    isEnteringForeground_ = YES;
}

- (void)enterBackground {
    UA_LTRACE(@"Enter Background.");

    // add app_background event
    [self addEvent:[UAEventAppBackground eventWithContext:nil]];
    
    //Set a blank session_id for app_exit events
    [session removeAllObjects];
    [session setValue:@"" forKey:@"session_id"];

    self.notificationUserInfo = nil;

    // Only place where a background task is created
    self.sendBackgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self.queue cancelAllOperations];
        [[UIApplication sharedApplication] endBackgroundTask:sendBackgroundTask_];
        self.sendBackgroundTask = UIBackgroundTaskInvalid;
    }];

    [self send];
}

- (void)invalidateBackgroundTask {
    if (sendBackgroundTask_ != UIBackgroundTaskInvalid) {
        UA_LTRACE(@"Ending analytics background task %u", sendBackgroundTask_);
        
        [[UIApplication sharedApplication] endBackgroundTask:sendBackgroundTask_];
        self.sendBackgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)didBecomeActive {
    UA_LTRACE(@"Application did become active.");
    
    // If this is the first 'inactive->active' transition in this session,
    // send 
    if (isEnteringForeground_) {
        isEnteringForeground_ = NO;
        
        //update the network connection_type value
        [self refreshSessionWhenNetworkChanged];

        //update session in case the app lunched from push while sleep in background
        [self refreshSessionWhenActive];

        //add app_foreground event
        [self addEvent:[UAEventAppForeground eventWithContext:nil]];
    }
    
    //add activity_started / AppActive event
    [self addEvent:[UAEventAppActive eventWithContext:nil]];
}

- (void)willResignActive {
    UA_LTRACE(@"Application will resign active.");
    
    //add activity_stopped / AppInactive event
    [self addEvent:[UAEventAppInactive eventWithContext:nil]];
}

#pragma mark -
#pragma mark NSUserDefaults

- (NSDate*)lastSendTime {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"X-UA-Last-Send-Time"] ?: [NSDate distantPast];
}

- (void)setLastSendTime:(NSDate *)lastSendTime {
    if (lastSendTime) {
        [[NSUserDefaults standardUserDefaults] setObject:lastSendTime forKey:@"X-UA-Last-Send-Time"];
    }
}

- (void)restoreFromDefault {
    
    // If the key is missing the int will end up being 0, which is what these checks are (not actual limits)
    int tmp = [[NSUserDefaults standardUserDefaults] integerForKey:@"X-UA-Max-Total"];
    
    if (tmp > 0) {
        x_ua_max_total = tmp;
    }

    tmp = [[NSUserDefaults standardUserDefaults] integerForKey:@"X-UA-Max-Batch"];
    
    if (tmp > 0) {
        x_ua_max_batch = tmp;
    }
    
    tmp = [[NSUserDefaults standardUserDefaults] integerForKey:@"X-UA-Max-Wait"];
    
    if (tmp > 0) {
        x_ua_max_wait = tmp;
    }
    
    tmp = [[NSUserDefaults standardUserDefaults] integerForKey:@"X-UA-Min-Batch-Interval"];
    
    if (tmp > 0) {
        x_ua_min_batch_interval = tmp;
    }
    
    
    /*
    UALOG(@"X-UA-Max-Total: %d", x_ua_max_total);
    UALOG(@"X-UA-Min-Batch-Interval: %d", x_ua_min_batch_interval);
    UALOG(@"X-UA-Max-Wait: %d", x_ua_max_wait);
    UALOG(@"X-UA-Max-Batch: %d", x_ua_max_batch);
    UALOG(@"X-UA-Last-Send-Time: %@", [lastSendTime description]);
    */
}

// TODO: Change this method call to a more descriptive name, and add some documentation
- (void)saveDefault {
    [[NSUserDefaults standardUserDefaults] setInteger:x_ua_max_total forKey:@"X-UA-Max-Total"];
    [[NSUserDefaults standardUserDefaults] setInteger:x_ua_max_batch forKey:@"X-UA-Max-Batch"];
    [[NSUserDefaults standardUserDefaults] setInteger:x_ua_max_wait forKey:@"X-UA-Max-Wait"];
    [[NSUserDefaults standardUserDefaults] setInteger:x_ua_min_batch_interval forKey:@"X-UA-Min-Batch-Interval"];

    /*
    UALOG(@"Response Headers Saved:");
    UALOG(@"X-UA-Max-Total: %d", x_ua_max_total);
    UALOG(@"X-UA-Min-Batch-Interval: %d", x_ua_min_batch_interval);
    UALOG(@"X-UA-Max-Wait: %d", x_ua_max_wait);
    UALOG(@"X-UA-Max-Batch: %d", x_ua_max_batch);
    */
}

#pragma mark -
#pragma mark Analytics

- (void)handleNotification:(NSDictionary*)userInfo inApplicationState:(UIApplicationState)applicationState {
    if (applicationState == UIApplicationStateActive) {
        [self addEvent:[UAEventPushReceived eventWithContext:userInfo]];
    } else {
        self.notificationUserInfo = userInfo;
    }

}

- (void)addEvent:(UAEvent *)event {
    if (self.config.analyticsEnabled) {
        UA_LTRACE(@"Add event type=%@ time=%@ data=%@", [event getType], event.time, event.data);    
        [[UAAnalyticsDBManager shared] addEvent:event withSession:session];    
        self.databaseSize += [event getEstimatedSize];
        if (oldestEventTime == 0) {
            oldestEventTime = [event.time doubleValue];
        }
        // If the app is in the background without a background task id, then this is a location
        // event, and we should attempt to send. 
        UIApplicationState appState = [[UIApplication sharedApplication] applicationState];
        BOOL isLocation = [event isKindOfClass:[UALocationEvent class]];
        if (appState == UIApplicationStateActive ||
            (self.sendBackgroundTask == UIBackgroundTaskInvalid && appState == UIApplicationStateBackground && isLocation)) {
            [self send];
        }
    }
}

// We send headers on all response codes, so let's set those values before checking for != 200
// NOTE: NSURLHTTPResponse converts header names to title case, so use the X-Ua-Header-Name format
- (void)updateAnalyticsParametersWithHeaderValues:(NSHTTPURLResponse *)response {
    if ([response allHeaderFields]) {
        int tmp = 0;
        
        id maxTotalValue = [[response allHeaderFields] objectForKey:@"X-UA-Max-Total"];
        if (maxTotalValue) {
            tmp = [maxTotalValue intValue] * 1024;//value returned in KB
            
            if (tmp > 0) {
                
                if(tmp >= X_UA_MAX_TOTAL) {
                    x_ua_max_total = X_UA_MAX_TOTAL;
                } else {
                    x_ua_max_total = tmp;
                }
                
            } else {
                x_ua_max_total = X_UA_MAX_TOTAL;
            }
        }

        id maxBatchValue = [[response allHeaderFields] objectForKey:@"X-UA-Max-Batch"];
        if (maxBatchValue) {
            tmp = [maxBatchValue intValue] * 1024;//value return in KB
            
            if (tmp > 0) {
                
                if (tmp >= X_UA_MAX_BATCH) {
                    x_ua_max_batch = X_UA_MAX_BATCH;
                } else {
                    x_ua_max_batch = tmp;
                }
                
            } else {
                x_ua_max_batch = X_UA_MAX_BATCH;
            }
        }


        id maxWaitValue = [[response allHeaderFields] objectForKey:@"X-UA-Max-Wait"];
        if (maxWaitValue) {
            tmp = [maxWaitValue intValue];
            
            if (tmp >= X_UA_MAX_WAIT) {
                x_ua_max_wait = X_UA_MAX_WAIT;
            } else {
                x_ua_max_wait = tmp;
            }
        }

        id minBatchValue = [[response allHeaderFields] objectForKey:@"X-UA-Min-Batch-Interval"];
        if (minBatchValue) {
            tmp = [minBatchValue intValue];
            
            if (tmp <= X_UA_MIN_BATCH_INTERVAL) {
                x_ua_min_batch_interval = X_UA_MIN_BATCH_INTERVAL;
            } else {
                x_ua_min_batch_interval = tmp;
            }
        }
        
        [self saveDefault];
    }
}

#pragma mark - 
#pragma mark Custom Property Setters

- (void)setSendInterval:(int)newVal {
    if(newVal < x_ua_min_batch_interval) {
        sendInterval_ = x_ua_min_batch_interval;
    } else if (newVal > x_ua_max_wait) {
        sendInterval_ = x_ua_max_wait;
    } else {
        sendInterval_ = newVal;
    }
}

#pragma mark - 
#pragma mark Send Logic

- (void)resetEventsDatabaseStatus {
    self.databaseSize = [[UAAnalyticsDBManager shared] sizeInBytes];

    NSArray *events = [[UAAnalyticsDBManager shared] getEvents:1];
    if ([events count] > 0) {
        NSDictionary *event = [events objectAtIndex:0];
        oldestEventTime = [[event objectForKey:@"time"] doubleValue];
    } else {
        oldestEventTime = 0;
    }

    UA_LTRACE(@"Database size: %d", databaseSize_);
    UA_LTRACE(@"Oldest Event: %f", oldestEventTime);
}

- (BOOL)hasEventsToSend {
    return databaseSize_ > 0 && [[UAAnalyticsDBManager shared] eventCount] > 0;
}

- (BOOL)shouldSendAnalytics {
    if (!self.config.analyticsEnabled) {
        UA_LTRACE("Analytics disabled.");
        return NO;
    }

    if (![self hasEventsToSend]) {
        UA_LTRACE(@"No analytics events to upload");
        return NO;
    }
    
    if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) {
        // If the app is in the background and there is a valid background task to upload events
        if (sendBackgroundTask_ != UIBackgroundTaskInvalid) {
            return YES;
        } else {
            // There is no background task, and the app is in the background, it is likely that
            // this is a location related event and we should only send every 15 minutes
            NSTimeInterval timeSinceLastSend = [[NSDate date] timeIntervalSinceDate:self.lastSendTime];
            return timeSinceLastSend > X_UA_MIN_BACKGROUND_LOCATION_INTERVAL;
        }
    }
    
    return YES;
}

- (UAHTTPRequest*)analyticsRequest {
    NSString *urlString = [NSString stringWithFormat:@"%@%@", self.config.analyticsURL, @"/warp9/"];
    UAHTTPRequest *request = [UAHTTPRequest requestWithURLString:urlString];
    request.compressBody = YES;//enable GZIP
    request.HTTPMethod = @"POST";
    
    // Required Items
    [request addRequestHeader:@"X-UA-Device-Family" value:[UIDevice currentDevice].systemName];
    [request addRequestHeader:@"X-UA-Sent-At" value:[NSString stringWithFormat:@"%f",[[NSDate date] timeIntervalSince1970]]];
    [request addRequestHeader:@"X-UA-Package-Name" value:[[[NSBundle mainBundle] infoDictionary] objectForKey:(id)kCFBundleIdentifierKey]];
    [request addRequestHeader:@"X-UA-Package-Version" value:packageVersion];
    [request addRequestHeader:@"X-UA-ID" value:[UAUtils deviceID]];
    [request addRequestHeader:@"X-UA-User-ID" value:[UAUser defaultUser].username];
    [request addRequestHeader:@"X-UA-App-Key" value:[UAirship shared].config.appKey];
    
    // Optional Items
    [request addRequestHeader:@"X-UA-Lib-Version" value:[UAirshipVersion get]];
    [request addRequestHeader:@"X-UA-Device-Model" value:[UAUtils deviceModelName]];
    [request addRequestHeader:@"X-UA-OS-Version" value:[[UIDevice currentDevice] systemVersion]];
    [request addRequestHeader:@"Content-Type" value: @"application/json"];
    [request addRequestHeader:@"X-UA-Timezone" value:[[NSTimeZone defaultTimeZone] name]];
    [request addRequestHeader:@"X-UA-Locale-Language" value:[[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode]];
    [request addRequestHeader:@"X-UA-Locale-Country" value:[[NSLocale currentLocale] objectForKey: NSLocaleCountryCode]];
    [request addRequestHeader:@"X-UA-Locale-Variant" value:[[NSLocale currentLocale] objectForKey: NSLocaleVariantCode]];

    return request;
}

// Clean up event data for sending.
// Enforce max batch limits
// Loop through events and discard DB-only items, format the JSON data field
// as a dictionary
- (NSArray*) prepareEventsForUpload {

    // Delete older events until upload size threshold is met
    while (databaseSize_ > x_ua_max_total) {
        UA_LTRACE(@"Database exceeds max size of %d bytes... Deleting oldest session.", x_ua_max_total);
        [[UAAnalyticsDBManager shared] deleteOldestSession];
        [self resetEventsDatabaseStatus];
    }

    int eventCount = [[UAAnalyticsDBManager shared] eventCount];
    if (eventCount <= 0) {
        return nil;
    }

    int avgEventSize = databaseSize_ / eventCount;
    if (avgEventSize <= 0) {
        return nil;
    }

    int actualSize = 0;
    int batchEventCount = 0;
    
    NSArray *events = [[UAAnalyticsDBManager shared] getEvents:x_ua_max_batch/avgEventSize];
    NSArray *topLevelKeys = [NSArray arrayWithObjects:@"type", @"time", @"event_id", @"data", nil];

    for (NSMutableDictionary *event in events) {
        actualSize += [[event objectForKey:@"event_size"] intValue];
        
        if (actualSize <= x_ua_max_batch) {
            batchEventCount++; 
        } else {
            UA_LTRACE(@"Met batch limit.");
            break;
        }
        
        // The event data returned by the DB is a binary plist. Deserialize now.
        NSMutableDictionary *eventData = nil;
        NSData *serializedEventData = (NSData *)[event objectForKey:@"data"];
        
        if (serializedEventData) {
            NSString *errString = nil;
            eventData = (NSMutableDictionary *)[NSPropertyListSerialization
                                                propertyListFromData:serializedEventData
                                                mutabilityOption:NSPropertyListMutableContainersAndLeaves
                                                format:NULL /* an out param */
                                                errorDescription:&errString];
            
            if (errString) {
                UA_LTRACE("Deserialization Error: %@", errString);
                [errString release];//must be relased by caller per docs
            }
        }
        
        // Always include a data entry, even if it is empty
        if (!eventData) {
            eventData = [[[NSMutableDictionary alloc] init] autorelease];
        }
        
        [eventData setValue:[event objectForKey:@"session_id"] forKey:@"session_id"];
        [event setValue:eventData forKey:@"data"];
        
        // Remove unused DB values
        for (NSString *key in [event allKeys]) {
            if (![topLevelKeys containsObject:key]) {
                [event removeObjectForKey:key];
            }
        }
    }
    
    if (batchEventCount < [events count]) {
        events = [events subarrayWithRange:NSMakeRange(0, batchEventCount)];
    }
    
    return events;
}

- (NSTimeInterval)timeToWaitBeforeSendingNextBatch {
    NSTimeInterval delay = 0;
    NSTimeInterval timeSinceLastSend = [[NSDate date] timeIntervalSinceDate:self.lastSendTime];
    if (timeSinceLastSend < x_ua_min_batch_interval) {
        delay = x_ua_min_batch_interval - timeSinceLastSend;
    }
    return delay;
}

- (UAHTTPConnectionOperation *)sendOperationWithEvents:(NSArray *)events {

    UAHTTPRequest *analyticsRequest = [self analyticsRequest];
    
    UA_SBJsonWriter *writer = [[UA_SBJsonWriter alloc] autorelease];
    
    writer.humanReadable = NO;//strip whitespace
    [analyticsRequest appendBodyData:[[writer stringWithObject:events] dataUsingEncoding:NSUTF8StringEncoding]];
    
    writer.humanReadable = YES; //turn on formatting for debugging
    UA_LTRACE(@"Sending to server: %@", self.config.analyticsURL);
    UA_LTRACE(@"Sending analytics headers: %@", [analyticsRequest.headers descriptionWithLocale:nil indent:1]);
    UA_LTRACE(@"Sending analytics body: %@", [writer stringWithObject:events]);

    UAHTTPConnectionSuccessBlock successBlock = ^(UAHTTPRequest *request){
        UA_LDEBUG(@"Analytics data sent successfully. Status: %d", [request.response statusCode]);
        UA_LTRACE(@"responseData=%@, length=%d", request.responseString, [request.responseData length]);

        // Update analytics settings with new header values
        [self updateAnalyticsParametersWithHeaderValues:request.response];
        
        if ([request.response statusCode] == 200) {
            [[UAAnalyticsDBManager shared] deleteEvents:events];
            [self resetEventsDatabaseStatus];
            self.lastSendTime = [NSDate date];
        } else {
            UA_LTRACE(@"Send analytics data request failed: %d", [request.response statusCode]);
        }
    };

    UAHTTPConnectionFailureBlock failureBlock = ^(UAHTTPRequest *request){
        UA_LTRACE(@"Send analytics data request failed.");
    };

    UAHTTPConnectionOperation *operation = [UAHTTPConnectionOperation operationWithRequest:analyticsRequest
                                                                                 onSuccess:successBlock
                                                                                 onFailure:failureBlock];
    return operation;
}

- (NSBlockOperation *)batchOperationWithCompletionBlock:(UAAnalyticsUploadCompletionBlock)completionBlock {

    NSBlockOperation *batchOperation = [NSBlockOperation blockOperationWithBlock:^{

        //in case the facts on the ground have changed since we last checked
        if (![self shouldSendAnalytics]) {
            UA_LTRACE(@"shouldSendAnalytics returned NO, skiping batchOperation");
            completionBlock();
        }

        NSArray* events = [self prepareEventsForUpload];

        //this could indicate a read problem, or simply an empty database
        if (!events) {
            UA_LTRACE(@"Empty database or error parsing events into array, skipping batchOperation");
            completionBlock();
            return;
        }

        //unlikely, due to the checks above, but theoretically possible
        if (events.count == 0) {
            UA_LTRACE(@"No events to upload, skipping batchOperation");
            completionBlock();
            return;
        }

        UAHTTPConnectionOperation *sendOperation = [self sendOperationWithEvents:events];

        [self.queue addOperation:sendOperation];

        NSBlockOperation *rebatchOperation = [NSBlockOperation blockOperationWithBlock:^{
            //if we're not in the background, and there's still stuff to send, create a new delay/batch and add them
            //otherwise, we should complete here and return
            BOOL moreBatchesNecessary = [self hasEventsToSend];

            if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive && moreBatchesNecessary) {
                [self batchAndSendEventsWithCompletionBlock:completionBlock];
            } else {
                if (!moreBatchesNecessary) {
                    UA_LTRACE(@"no more events to upload");
                } else {
                    UA_LTRACE(@"application state is background or inactive, not sending any more batches");
                }
                completionBlock();
            }
        }];

        [rebatchOperation addDependency:sendOperation];

        [self.queue addOperation:rebatchOperation];
    }];

    return batchOperation;
}

- (void)batchAndSendEventsWithCompletionBlock:(UAAnalyticsUploadCompletionBlock)completionBlock {

    NSTimeInterval delay = [self timeToWaitBeforeSendingNextBatch];

    if (delay) {
        UA_LTRACE(@"Scheduling analytics batch update in %g seconds", delay);
    }

    UADelayOperation *delayOperation = [UADelayOperation operationWithDelayInSeconds:delay];
    NSBlockOperation *batchOperation = [self batchOperationWithCompletionBlock:completionBlock];

    [batchOperation addDependency:delayOperation];

    [self.queue addOperation:delayOperation];
    [self.queue addOperation:batchOperation];
}

//NOTE: this method is intended to be called from the main thread
- (void)sendEventsWithCompletionBlock:(UAAnalyticsUploadCompletionBlock)completionBlock {
    UA_LTRACE(@"Attemping to send analytics");

    if (self.isSending) {
        UA_LTRACE(@"Analytics upload in progress, skipping analytics send");
        return;
    }

    if (![self shouldSendAnalytics]) {
        UA_LTRACE(@"ShouldSendAnalytics returned NO, skipping analytics send");
        completionBlock();
        return;
    }

    self.isSending = YES;

    [self batchAndSendEventsWithCompletionBlock:completionBlock];
}

//NOTE: this method is intended to be called from the main thread
- (void)send {
    [self sendEventsWithCompletionBlock:^{
        // Marshall this onto the main queue, in case the block is called in the background 
        [[NSOperationQueue mainQueue] addOperation:[NSBlockOperation blockOperationWithBlock:^{
            [self invalidateBackgroundTask];
            self.isSending = NO;
        }]];
    }];
}

@end
