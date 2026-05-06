#include <stdio.h>
#include <string.h>

#include "protocol.h"
#include "datalink.h"

#define MAX_SEQ 15
#define NR_BUFS ((MAX_SEQ + 1) / 2)

#define DATA_TIMER 1500
#define ACK_TIMER 120

#define DATA_FRAME_LEN (3 + PKT_LEN + 4)
#define CTRL_FRAME_LEN (2 + 4)
#define FRAME_WIRE_BYTES(len) (2 * (len) + 2)
#define MAX_PHL_BACKLOG (NR_BUFS * FRAME_WIRE_BYTES(DATA_FRAME_LEN))

struct FRAME {
    unsigned char kind;
    unsigned char ack;
    unsigned char seq;
    unsigned char data[PKT_LEN];
    unsigned int padding;
};

static unsigned char ack_expected = 0;
static unsigned char next_frame_to_send = 0;
static unsigned char frame_expected = 0;
static unsigned char too_far = NR_BUFS;
static unsigned char nbuffered = 0;

static unsigned char out_buf[NR_BUFS][PKT_LEN];
static unsigned char in_buf[NR_BUFS][PKT_LEN];
static int arrived[NR_BUFS];

static int phl_ready = 1;
static int ack_pending = 0;
static int ack_due = 0;
static int nak_pending = 0;
static int no_nak = 1;

static unsigned char inc_seq(unsigned char n)
{
    return n < MAX_SEQ ? n + 1 : 0;
}

static int between(unsigned char a, unsigned char b, unsigned char c)
{
    return ((a <= b) && (b < c)) || ((c < a) && (a <= b)) || ((b < c) && (c < a));
}

static unsigned char current_ack(void)
{
    return frame_expected == 0 ? MAX_SEQ : frame_expected - 1;
}

static int can_queue_frame(void)
{
    return phl_ready || phl_sq_len() < MAX_PHL_BACKLOG;
}

static void clear_ack_state(void)
{
    stop_ack_timer();
    ack_pending = 0;
    ack_due = 0;
    nak_pending = 0;
}

static void put_frame(unsigned char *frame, int len)
{
    *(unsigned int *)(frame + len) = crc32(frame, len);
    send_frame(frame, len + 4);
    phl_ready = 0;
}

static void queue_ack(void)
{
    ack_pending = 1;
    if (!ack_due && !nak_pending)
        start_ack_timer(ACK_TIMER);
}

static void request_nak(void)
{
    if (!no_nak)
        return;

    dbg_warning("Request NAK for %d\n", (int)frame_expected);
    ack_pending = 1;
    ack_due = 0;
    nak_pending = 1;
    no_nak = 0;
    stop_ack_timer();
}

static void send_frame_kind(unsigned char kind, unsigned char frame_nr)
{
    struct FRAME s;

    memset(&s, 0, sizeof s);
    s.kind = kind;
    s.ack = current_ack();

    if (kind == FRAME_DATA) {
        s.seq = frame_nr;
        memcpy(s.data, out_buf[frame_nr % NR_BUFS], PKT_LEN);
        dbg_frame("Send DATA %d %d, ID %d\n", (int)s.seq, (int)s.ack, *(unsigned short *)s.data);
        put_frame((unsigned char *)&s, 3 + PKT_LEN);
        start_timer(frame_nr, DATA_TIMER);
    } else {
        if (kind == FRAME_ACK)
            dbg_frame("Send ACK  %d\n", (int)s.ack);
        else
            dbg_frame("Send NAK  %d\n", (int)inc_seq(s.ack));
        put_frame((unsigned char *)&s, 2);
    }

    clear_ack_state();
}

static void maybe_send_control_frame(void)
{
    if (!can_queue_frame())
        return;

    if (nak_pending) {
        send_frame_kind(FRAME_NAK, 0);
        return;
    }

    if (ack_due)
        send_frame_kind(FRAME_ACK, 0);
}

static void handle_ack(unsigned char ack)
{
    while (between(ack_expected, ack, next_frame_to_send)) {
        dbg_frame("Acked DATA %d, slide SEND window\n", (int)ack_expected);
        stop_timer(ack_expected);
        nbuffered--;
        ack_expected = inc_seq(ack_expected);
    }
}

static void deliver_frames(void)
{
    int delivered = 0;

    while (arrived[frame_expected % NR_BUFS]) {
        int index;

        index = frame_expected % NR_BUFS;
        dbg_frame("Deliver DATA %d, ID %d\n", (int)frame_expected, *(unsigned short *)in_buf[index]);
        put_packet(in_buf[index], PKT_LEN);
        arrived[index] = 0;
        frame_expected = inc_seq(frame_expected);
        too_far = inc_seq(too_far);
        no_nak = 1;
        delivered = 1;
    }

    if (delivered) {
        dbg_frame("Slide RECV window, expect %d next\n", (int)frame_expected);
        queue_ack();
    }
}

int main(int argc, char **argv)
{
    int event, arg;
    int len;
    struct FRAME f;

    protocol_init(argc, argv);
    lprintf("Designed by Jiang Yanjun, build: " __DATE__ "  " __TIME__ "\n");

    memset(arrived, 0, sizeof arrived);
    enable_network_layer();

    for (;;) {
        event = wait_for_event(&arg);

        switch (event) {
        case NETWORK_LAYER_READY:
            if (nak_pending && can_queue_frame()) {
                send_frame_kind(FRAME_NAK, 0);
                break;
            }

            get_packet(out_buf[next_frame_to_send % NR_BUFS]);
            nbuffered++;
            send_frame_kind(FRAME_DATA, next_frame_to_send);
            next_frame_to_send = inc_seq(next_frame_to_send);
            break;

        case PHYSICAL_LAYER_READY:
            phl_ready = 1;
            break;

        case FRAME_RECEIVED:
            len = recv_frame((unsigned char *)&f, sizeof f);
            if (len < CTRL_FRAME_LEN || crc32((unsigned char *)&f, len) != 0) {
                dbg_warning("**** Receiver Error, Bad CRC Checksum\n");
                request_nak();
                break;
            }

            switch (f.kind) {
            case FRAME_DATA:
                if (len != DATA_FRAME_LEN) {
                    dbg_warning("Bad DATA frame length %d\n", len);
                    request_nak();
                    break;
                }

                dbg_frame("Recv DATA %d %d, ID %d\n", (int)f.seq, (int)f.ack, *(unsigned short *)f.data);

                if (between(frame_expected, f.seq, too_far)) {
                    if (f.seq != frame_expected)
                        request_nak();
                    else
                        queue_ack();

                    if (!arrived[f.seq % NR_BUFS]) {
                        memcpy(in_buf[f.seq % NR_BUFS], f.data, PKT_LEN);
                        arrived[f.seq % NR_BUFS] = 1;
                    }

                    deliver_frames();
                } else {
                    dbg_warning("Ignore out-of-window DATA %d\n", (int)f.seq);
                    queue_ack();
                }

                handle_ack(f.ack);
                break;

            case FRAME_ACK:
                if (len != CTRL_FRAME_LEN) {
                    dbg_warning("Bad ACK frame length %d\n", len);
                    break;
                }

                dbg_frame("Recv ACK  %d\n", (int)f.ack);
                handle_ack(f.ack);
                break;

            case FRAME_NAK:
            {
                unsigned char resend;

                if (len != CTRL_FRAME_LEN) {
                    dbg_warning("Bad NAK frame length %d\n", len);
                    break;
                }

                resend = inc_seq(f.ack);
                dbg_frame("Recv NAK  %d\n", (int)resend);

                if (between(ack_expected, resend, next_frame_to_send)) {
                    dbg_event("---- Resend DATA %d on NAK\n", (int)resend);
                    send_frame_kind(FRAME_DATA, resend);
                }

                handle_ack(f.ack);
                break;
            }

            default:
                dbg_warning("Ignore unknown frame kind %d\n", (int)f.kind);
                break;
            }
            break;

        case DATA_TIMEOUT:
            dbg_event("---- DATA %d timeout\n", arg);
            send_frame_kind(FRAME_DATA, (unsigned char)arg);
            break;

        case ACK_TIMEOUT:
            if (ack_pending && !nak_pending) {
                dbg_event("---- ACK timeout\n");
                ack_due = 1;
            }
            break;
        }

        maybe_send_control_frame();

        if (nbuffered < NR_BUFS && can_queue_frame())
            enable_network_layer();
        else
            disable_network_layer();
    }
}
