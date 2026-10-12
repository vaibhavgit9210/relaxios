#import <Foundation/Foundation.h>
extern void relaxios_harness_start(void);
__attribute__((constructor)) static void boot(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ relaxios_harness_start(); });
}
