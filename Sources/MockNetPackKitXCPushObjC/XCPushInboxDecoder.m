//
//  XCPushInboxDecoder.m
//  MockNetPackKit
//
//  实现见 .h：Sync protobuf → bussdata(JSON 子字典) → pretty JSON；
//  fallback：raw 直接 JSON；失败返回 nil。
//

#import "XCPushInboxDecoder.h"

/// 将任意 JSON 对象（NSDictionary/NSArray）序列化为 pretty JSON 文本。
static NSString *_Nullable MNPJSONPretty(id json) {
    if (![NSJSONSerialization isValidJSONObject:json]) {
        return nil;
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:json
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:nil];
    if (!out) {
        return nil;
    }
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

NSString *_Nullable MNPXCPushDecodeToJSON(NSData *raw) {
    if (raw.length == 0) {
        NSLog(@"[MNP-decoder] empty raw -> nil");
        return nil;
    }

    // 路径 1：raw 是 Sync protobuf 信封（bizType=1 chat 包）。
    Class syncCls = NSClassFromString(@"Sync");
    NSLog(@"[MNP-decoder] rawLen=%lu, SyncClass=%@", (unsigned long)raw.length, syncCls != nil ? @"found" : @"nil");
    if (syncCls && [syncCls respondsToSelector:@selector(parseFromData:error:)]) {
        @try {
            // GPBRootObject +parseFromData:error:（两参数类方法，用 NSInvocation 调）。
            NSMethodSignature *sig = [syncCls methodSignatureForSelector:@selector(parseFromData:error:)];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(parseFromData:error:)];
                [inv setTarget:syncCls];
                NSError *err = nil;
                [inv setArgument:&raw atIndex:2];
                [inv setArgument:&err atIndex:3];
                [inv invoke];
                void *result = NULL;
                [inv getReturnValue:&result];
                // GPB 返回 autoreleased 对象（FDSocketService MRC）：__bridge 不转移所有权。
                id msg = (__bridge id)result;
                NSLog(@"[MNP-decoder] parseFromData -> %@", msg != nil ? @"ok" : @"nil");
                if (msg && [msg respondsToSelector:@selector(bussdata)]) {
                    id inner = [msg valueForKey:@"bussdata"];
                    NSLog(@"[MNP-decoder] bussdata class=%@ len=%lu",
                          NSStringFromClass([inner class]), (unsigned long)[(NSData *)inner length]);
                    if ([inner isKindOfClass:[NSData class]]) {
                        id dic = [NSJSONSerialization JSONObjectWithData:inner options:0 error:nil];
                        NSLog(@"[MNP-decoder] inner JSON parse -> %@", dic != nil ? @"ok" : @"nil(bussdata不是JSON)");
                        if ([dic isKindOfClass:[NSDictionary class]]) {
                            // 一期 coder：取 "data" 子字典（外层信封字段对调试无价值）。
                            id innerData = ((NSDictionary *)dic)[@"data"] ?: dic;
                            NSString *out = MNPJSONPretty(innerData);
                            NSLog(@"[MNP-decoder] path1 success, outLen=%lu", (unsigned long)out.length);
                            return out;
                        }
                    }
                } else {
                    NSLog(@"[MNP-decoder] msg respondsToSelector:bussdata = NO");
                }
            }
        } @catch (__unused NSException *e) {
            NSLog(@"[MNP-decoder] parse exception: %@", e);
        }
    }

    // 路径 2：raw 直接是 JSON（bizType=2 push 状态包）。
    id dic = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    NSLog(@"[MNP-decoder] path2 raw-as-JSON -> %@", dic != nil ? @"ok" : @"nil(raw非JSON)");
    if ([dic isKindOfClass:[NSDictionary class]]) {
        return MNPJSONPretty(dic);
    }
    NSLog(@"[MNP-decoder] all paths failed -> nil");
    return nil;
}

// MARK: - L7.2b 模拟推送（能力线 L7 模拟推送形态）

/// 从序列化 Packet（如 ACK data）解析 msgId（动态 GPB 解包；解不出返回 0）。
/// 用于模拟推送 ACK 拦截（决策 D4）：业务对假包发的 ACK 经此提取 msgId，
/// SDK 判定 ∈ fakeMsgId 集合 → 丢弃不上行。
uint64_t MNPPacketMsgId(NSData *raw) {
    if (raw.length == 0) {
        return 0;
    }
    Class packetCls = NSClassFromString(@"Packet");
    if (!packetCls || ![packetCls respondsToSelector:@selector(parseFromData:error:)]) {
        return 0;
    }
    @try {
        NSMethodSignature *sig = [packetCls methodSignatureForSelector:@selector(parseFromData:error:)];
        if (!sig) {
            return 0;
        }
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:@selector(parseFromData:error:)];
        [inv setTarget:packetCls];
        NSError *err = nil;
        [inv setArgument:&raw atIndex:2];
        [inv setArgument:&err atIndex:3];
        [inv invoke];
        void *result = NULL;
        [inv getReturnValue:&result];
        id pkt = (__bridge id)result;
        if (!pkt || ![pkt respondsToSelector:@selector(msgId)]) {
            return 0;
        }
        NSNumber *n = [pkt valueForKey:@"msgId"];
        return n.unsignedLongLongValue;
    } @catch (__unused NSException *e) {
        NSLog(@"[MNP-packet] parse msgId exception: %@", e);
        return 0;
    }
}
