#import "MeteorClient.h"
#import "BSONIdGenerator.h"
#import "srp/srp.h"

@interface MeteorClient ()

@property (assign, nonatomic) struct SRPUser *usr;

@end

@implementation MeteorClient

- (id)init {
    self = [super init];
    if (self) {
        self.collections = [NSMutableDictionary dictionary];
        self.subscriptions = [NSMutableDictionary dictionary];
        // TODO: subscription version should be set here
    }
    return self;
}

- (void)resetCollections {
    [self.collections removeAllObjects];
}

#pragma mark MeteorClient public API

- (void)sendWithMethodName:(NSString *)methodName parameters:(NSArray *)parameters {
    [self.ddp methodWith:[[BSONIdGenerator generate] substringToIndex:15]
                  method:methodName
              parameters:parameters];
}

- (void)addSubscription:(NSString *)subscriptionName {
    [self.subscriptions setObject:[NSArray array]
                           forKey:subscriptionName];
    NSString *uid = [[BSONIdGenerator generate] substringToIndex:15];
    [self.ddp subscribeWith:uid name:subscriptionName parameters:nil];
}

#pragma mark <ObjectiveDDPDelegate>

- (void)didOpen {
    [self.authDelegate didConnectToMeteorServer];
    // TODO: pre1 should be a setting
    [self.ddp connectWithSession:nil version:@"pre1" support:nil];
}

- (void)didReceiveMessage:(NSDictionary *)message {
    NSString *msg = [message objectForKey:@"msg"];

    // TODO: handle auth login failure with auth delegate call (with meteor server error message)
    if (msg && [msg isEqualToString:@"result"]
            && message[@"result"]
            && message[@"result"][@"B"]
            && message[@"result"][@"identity"]
            && message[@"result"][@"salt"]) {
        NSDictionary *response = message[@"result"];
        [self.authDelegate didReceiveLoginChallengeWithResponse:response];
    } else if (msg && [msg isEqualToString:@"result"]
            && message[@"result"]
            && message[@"result"][@"id"]
            && message[@"result"][@"HAMK"]
            && message[@"result"][@"token"]) {
        NSDictionary *response = message[@"result"];
        [self.authDelegate didReceiveHAMKVerificationWithResponse:response];
    } else if (msg && [msg isEqualToString:@"added"]
            && message[@"collection"]) {
        NSDictionary *object = [self _parseObjectAndAddToCollection:message];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"added" object:self userInfo:object];
    } else if (msg && [msg isEqualToString:@"removed"]
            && message[@"collection"]) {
        [self _parseRemoved:message];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"removed" object:self userInfo:nil];
    } else if (msg && [msg isEqualToString:@"changed"]
            && message[@"collection"]) {
        NSDictionary *object = [self _parseObjectAndUpdateCollection:message];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"changed" object:self userInfo:object];
    } else if (msg && [msg isEqualToString:@"connected"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"connected" object:nil];
        if (self.sessionToken) {
            NSArray *params = @[@{@"resume": self.sessionToken}];
            [self sendWithMethodName:@"login"
                          parameters:params];
        }
        [self makeMeteorDataSubscriptions];
    }
}

- (void)didReceiveConnectionError:(NSError *)error {
    NSLog(@"================> didReceiveConnectionError: %@", error);
}

#pragma mark Meteor Data Managment

- (void)makeMeteorDataSubscriptions {
    for (NSString *key in [self.subscriptions allKeys]) {
        NSString *uid = [[BSONIdGenerator generate] substringToIndex:15];
        [self.ddp subscribeWith:uid name:key parameters:nil];
    }
}

- (NSDictionary *)_parseObjectAndUpdateCollection:(NSDictionary *)message {
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"(_id like %@)", message[@"id"]];
    NSMutableArray *collection = self.collections[message[@"collection"]];
    NSArray *filteredArray = [collection filteredArrayUsingPredicate:pred];

    NSMutableDictionary *object = filteredArray[0];

    for (id key in message[@"fields"]) {
        object[key] = message[@"fields"][key];
    }

    return object;
}

- (NSDictionary *)_parseObjectAndAddToCollection:(NSDictionary *)message {
    NSMutableDictionary *object = [NSMutableDictionary dictionaryWithDictionary:@{@"_id": message[@"id"]}];

    for (id key in message[@"fields"]) {
        object[key] = message[@"fields"][key];
    }

    if (!self.collections[message[@"collection"]]) {
        self.collections[message[@"collection"]] = [NSMutableArray array];
    }

    NSMutableArray *collection = self.collections[message[@"collection"]];

    [collection addObject:object];

    return object;
}

- (void)_parseRemoved:(NSDictionary *)message {
    NSString *removedId = [message objectForKey:@"id"];
    int indexOfRemovedObject = 0;

    NSMutableArray *collection = self.collections[message[@"collection"]];

    for (NSDictionary *object in collection) {
        if ([object[@"_id"] isEqualToString:removedId]) {
            break;
        }
        indexOfRemovedObject++;
    }

    [collection removeObjectAtIndex:indexOfRemovedObject];
}

# pragma mark Meteor DDP Wrapper

SRP_HashAlgorithm alg     = SRP_SHA256;
SRP_NGType        ng_type = SRP_NG_1024;

- (NSString *)generateAuthVerificationKeyWithUsername:(NSString *)username password:(NSString *)password {
    //TODO: don't really need to keep bytes_A and len_A here, could remove them
    // and push into srp lib
    const unsigned char * bytes_A = 0;
    int len_A   = 0;
    const char * Astr = 0;
    const char * auth_username = 0;
    const char * username_str = [username cStringUsingEncoding:NSASCIIStringEncoding];
    const char * password_str = [password cStringUsingEncoding:NSASCIIStringEncoding];

    /* Begin authentication process */
    self.usr = srp_user_new(alg,
                            ng_type,
                            username_str,
                            password_str,
                            strlen(password_str),
                            NULL,
                            NULL);

    srp_user_start_authentication(self.usr,
                                  &auth_username,
                                  &bytes_A,
                                  &len_A,
                                  &Astr);

    return [NSString stringWithCString:Astr encoding:NSASCIIStringEncoding];
}

@end
