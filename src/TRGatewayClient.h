/*
  TRGatewayClient - 内网群控网关注册/心跳客户端（BSD socket / TCP JSON 行协议）
  功能：读取预置网关配置(GatewayHost+GatewayPort / GatewayToken)，生成并持久化设备 UUID，
       连接网关注册端口(默认 18081)，上报能力清单（capabilities/configs/screen/httpPort，
       宪法 7.3），定时 hello，断线退避重连；设置变更时重发 register 保持清单新鲜。
*/
#ifndef TRGatewayClient_h
#define TRGatewayClient_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TRGatewayClient : NSObject

+ (instancetype)sharedClient;

/// 读取 com.82flex.trollvnc 配置并开始连接（幂等）
- (void)start;

/// 停止连接与重连
- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* TRGatewayClient_h */
