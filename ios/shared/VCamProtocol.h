#ifndef VCAM_PROTOCOL_H
#define VCAM_PROTOCOL_H

#import <Foundation/Foundation.h>

static NSString *const VCamMasterDirectory = @"/var/mobile/Media/VCamSync";
static NSString *const VCamAppRelativeSubdir = @"Library/Caches/VCamSync";
static NSString *const VCamQueueFilename = @"queue.json";
static NSString *const VCamStateFilename = @"state.json";
static NSString *const VCamTargetsFilename = @"targets.json";
static NSString *const VCamMediaSubdir = @"media";
static NSString *const VCamCompanionBundleID = @"com.vcamsync.app";

static const char *const VCamDarwinNotifyQueueUpdated = "com.vcamsync.queueDidUpdate";
static const char *const VCamDarwinNotifyCursorAdvanced = "com.vcamsync.cursorDidAdvance";

static const uint16_t VCamLocalBridgePort = 18765;
static const uint16_t VCamDiscoveryUDPPort = 18766;

#endif /* VCAM_PROTOCOL_H */
