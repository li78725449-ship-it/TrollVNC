/*
  TRGatewayClient - 内网群控网关注册/心跳客户端
  功能：读取预置网关配置(GatewayURL / GatewayHost+GatewayPort / GatewayToken)，
       生成并持久化设备 UUID，连接网关 /ws/register，定时 hello，断线退避重连。
  iOS 13+ 使用 NSURLSessionWebSocketTask。
*/
#ifndef TRGatewayClient_h
#define TRGatewayClient_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TRGatewayClient : NSObject <NSURLSessionWebSocketDelegate>

+ (instancetype)sharedClient;

/// 读取 com.82flex.trollvnc 配置并开始连接（幂等）
- (void)start;

/// 停止连接与重连
- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* TRGatewayClient_h */
