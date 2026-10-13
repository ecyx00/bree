#ifndef BREE_TERMINATION_WATCHDOG_ATOMIC_H
#define BREE_TERMINATION_WATCHDOG_ATOMIC_H

#include <stdbool.h>
#include <stdatomic.h>

typedef struct {
    atomic_bool isArmed;
} BREEinationWatchdogLatch;

BREEinationWatchdogLatch BREEinationWatchdogLatchMake(void);
bool BREEinationWatchdogLatchClaim(BREEinationWatchdogLatch *latch);

#endif
