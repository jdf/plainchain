// C API over the Cap'n Proto session records (schema/session.capnp), so Swift
// can encode and decode them without C++ interop.
#ifndef CAPN_SESSION_H
#define CAPN_SESSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* An owned byte buffer; release with pc_buf_free. bytes is NULL on failure. */
typedef struct pc_buf { uint8_t *bytes; size_t len; } pc_buf;
/* A borrowed view, valid while the reader that produced it lives. */
typedef struct pc_bytes { const uint8_t *bytes; size_t len; } pc_bytes;

void pc_buf_free(pc_buf buf);

/* ---- Endpoint ---- */
pc_buf pc_endpoint_encode(const char *device_uid, const uint32_t *channels, size_t channel_count);

typedef struct pc_endpoint pc_endpoint;
pc_endpoint *pc_endpoint_read(const uint8_t *bytes, size_t len);   /* NULL if malformed */
const char *pc_endpoint_device_uid(const pc_endpoint *e);
size_t pc_endpoint_channel_count(const pc_endpoint *e);
uint32_t pc_endpoint_channel(const pc_endpoint *e, size_t index);
void pc_endpoint_free(pc_endpoint *e);

/* ---- ChainItem ---- */
pc_buf pc_chain_item_encode(const char *id, const char *type, const char *subtype, const char *manufacturer,
                            bool bypass, const uint8_t *state, size_t state_len, float input_gain_db);

typedef struct pc_chain_item pc_chain_item;
pc_chain_item *pc_chain_item_read(const uint8_t *bytes, size_t len);   /* NULL if malformed */
const char *pc_chain_item_id(const pc_chain_item *c);
const char *pc_chain_item_type(const pc_chain_item *c);
const char *pc_chain_item_subtype(const pc_chain_item *c);
const char *pc_chain_item_manufacturer(const pc_chain_item *c);
bool pc_chain_item_bypass(const pc_chain_item *c);
float pc_chain_item_input_gain_db(const pc_chain_item *c);
pc_bytes pc_chain_item_state(const pc_chain_item *c);
void pc_chain_item_free(pc_chain_item *c);

#ifdef __cplusplus
}
#endif

#endif
