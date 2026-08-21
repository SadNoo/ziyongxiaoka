#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/*
 * UFI103S/UFI001C physical-SIM power reset.
 *
 * The original Android DT identifies TLMM GPIO1 as SIM_EN and uses active
 * low polarity.  Requesting just this line through the GPIO character API
 * avoids direct register access: high disables the SIM supply, then low
 * enables it again.  Selector GPIOs 0, 2 and 3 are deliberately untouched.
 */

int main(void) {
    const char *chip = "/dev/gpiochip0";
    struct gpiohandle_request request = {0};
    struct gpiohandle_data values = {0};
    int chip_fd;

    chip_fd = open(chip, O_RDONLY | O_CLOEXEC);
    if (chip_fd < 0) {
        fprintf(stderr, "open %s: %s\n", chip, strerror(errno));
        return 1;
    }

    request.lineoffsets[0] = 1;
    request.flags = GPIOHANDLE_REQUEST_OUTPUT;
    request.default_values[0] = 1;
    request.lines = 1;
    snprintf(request.consumer_label, sizeof(request.consumer_label),
             "wangka-sim-reset");

    if (ioctl(chip_fd, GPIO_GET_LINEHANDLE_IOCTL, &request) < 0) {
        fprintf(stderr, "request GPIO1: %s\n", strerror(errno));
        close(chip_fd);
        return 1;
    }
    close(chip_fd);

    usleep(750000);
    values.values[0] = 0;
    if (ioctl(request.fd, GPIOHANDLE_SET_LINE_VALUES_IOCTL, &values) < 0) {
        fprintf(stderr, "set GPIO1 low: %s\n", strerror(errno));
        close(request.fd);
        return 1;
    }

    sleep(2);
    close(request.fd);
    puts("SIM_EN power cycle complete (high -> low)");
    return 0;
}
