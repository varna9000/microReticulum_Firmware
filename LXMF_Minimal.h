// LXMF_Minimal.h — Embedded LXMF parser/sender for microReticulum
// Handles single-packet (opportunistic) LXMF messages only.
// No external MsgPack dependency — all parsing/packing done with raw bytes.

#ifndef LXMF_MINIMAL_H
#define LXMF_MINIMAL_H

#include <Arduino.h>
#include <string>
#include <functional>

// microReticulum headers
#include <Reticulum.h>
#include <Identity.h>
#include <Destination.h>
#include <Packet.h>
#include <Transport.h>
#include <Bytes.h>

// LXMF constants
#define LXMF_HASH_LEN      16   // RNS truncated hash = 128 bits
#define LXMF_SIG_LEN       64   // Ed25519 signature
#define LXMF_HEADER_LEN    (LXMF_HASH_LEN + LXMF_SIG_LEN)  // 80 bytes

// ============================================================================
// Raw MsgPack helpers (no library needed)
// ============================================================================

namespace RawMsgPack {

    // Read a msgpack str OR bin starting at data[offset].
    // LXMF uses bin type (0xC4/C5/C6) for title and content fields.
    // Returns the content as a std::string and advances offset past it.
    // Returns empty string on any parse error.
    inline std::string read_bin_or_str(const uint8_t* data, size_t len, size_t& offset) {
        if (offset >= len) return "";
        uint8_t tag = data[offset++];
        size_t slen = 0;

        // --- str types ---
        if ((tag & 0xE0) == 0xA0) {
            // fixstr: 0xa0..0xbf, length in lower 5 bits
            slen = tag & 0x1F;
        } else if (tag == 0xD9 && offset < len) {
            // str 8
            slen = data[offset++];
        } else if (tag == 0xDA && offset + 1 < len) {
            // str 16
            slen = (data[offset] << 8) | data[offset + 1];
            offset += 2;
        } else if (tag == 0xDB && offset + 3 < len) {
            // str 32
            slen = ((uint32_t)data[offset] << 24) | ((uint32_t)data[offset+1] << 16) |
                   ((uint32_t)data[offset+2] << 8) | data[offset+3];
            offset += 4;
        }
        // --- bin types (used by LXMF reference implementation) ---
        else if (tag == 0xC4 && offset < len) {
            // bin 8
            slen = data[offset++];
        } else if (tag == 0xC5 && offset + 1 < len) {
            // bin 16
            slen = (data[offset] << 8) | data[offset + 1];
            offset += 2;
        } else if (tag == 0xC6 && offset + 3 < len) {
            // bin 32
            slen = ((uint32_t)data[offset] << 24) | ((uint32_t)data[offset+1] << 16) |
                   ((uint32_t)data[offset+2] << 8) | data[offset+3];
            offset += 4;
        } else {
            // Not a string or bin
            return "";
        }

        if (offset + slen > len) return "";
        std::string result((const char*)&data[offset], slen);
        offset += slen;
        return result;
    }

    // Skip one msgpack element at data[offset]. Advances offset.
    inline bool skip_element(const uint8_t* data, size_t len, size_t& offset) {
        if (offset >= len) return false;
        uint8_t tag = data[offset++];

        // nil, false, true
        if (tag == 0xC0 || tag == 0xC2 || tag == 0xC3) return true;

        // positive fixint (0x00..0x7f)
        if (tag <= 0x7F) return true;

        // negative fixint (0xe0..0xff)
        if (tag >= 0xE0) return true;

        // fixstr (0xa0..0xbf)
        if ((tag & 0xE0) == 0xA0) {
            size_t n = tag & 0x1F;
            offset += n;
            return offset <= len;
        }

        // fixarray (0x90..0x9f)
        if ((tag & 0xF0) == 0x90) {
            size_t n = tag & 0x0F;
            for (size_t i = 0; i < n; i++) {
                if (!skip_element(data, len, offset)) return false;
            }
            return true;
        }

        // fixmap (0x80..0x8f)
        if ((tag & 0xF0) == 0x80) {
            size_t n = tag & 0x0F;
            for (size_t i = 0; i < n * 2; i++) {
                if (!skip_element(data, len, offset)) return false;
            }
            return true;
        }

        // uint8, int8
        if (tag == 0xCC || tag == 0xD0) { offset += 1; return offset <= len; }
        // uint16, int16
        if (tag == 0xCD || tag == 0xD1) { offset += 2; return offset <= len; }
        // uint32, int32, float32
        if (tag == 0xCE || tag == 0xD2 || tag == 0xCA) { offset += 4; return offset <= len; }
        // uint64, int64, float64
        if (tag == 0xCF || tag == 0xD3 || tag == 0xCB) { offset += 8; return offset <= len; }

        // str 8
        if (tag == 0xD9 && offset < len) { size_t n = data[offset++]; offset += n; return offset <= len; }
        // str 16
        if (tag == 0xDA && offset + 1 < len) {
            size_t n = (data[offset] << 8) | data[offset+1]; offset += 2 + n; return offset <= len;
        }
        // str 32
        if (tag == 0xDB && offset + 3 < len) {
            size_t n = ((uint32_t)data[offset] << 24) | ((uint32_t)data[offset+1] << 16) |
                       ((uint32_t)data[offset+2] << 8) | data[offset+3];
            offset += 4 + n; return offset <= len;
        }

        // bin 8
        if (tag == 0xC4 && offset < len) { size_t n = data[offset++]; offset += n; return offset <= len; }
        // bin 16
        if (tag == 0xC5 && offset + 1 < len) {
            size_t n = (data[offset] << 8) | data[offset+1]; offset += 2 + n; return offset <= len;
        }
        // bin 32
        if (tag == 0xC6 && offset + 3 < len) {
            size_t n = ((uint32_t)data[offset] << 24) | ((uint32_t)data[offset+1] << 16) |
                       ((uint32_t)data[offset+2] << 8) | data[offset+3];
            offset += 4 + n; return offset <= len;
        }

        // array 16
        if (tag == 0xDC && offset + 1 < len) {
            size_t n = (data[offset] << 8) | data[offset+1]; offset += 2;
            for (size_t i = 0; i < n; i++) { if (!skip_element(data, len, offset)) return false; }
            return true;
        }

        // map 16
        if (tag == 0xDE && offset + 1 < len) {
            size_t n = (data[offset] << 8) | data[offset+1]; offset += 2;
            for (size_t i = 0; i < n * 2; i++) { if (!skip_element(data, len, offset)) return false; }
            return true;
        }

        // ext types
        if (tag == 0xD4) { offset += 2; return offset <= len; }  // fixext 1
        if (tag == 0xD5) { offset += 3; return offset <= len; }  // fixext 2
        if (tag == 0xD6) { offset += 5; return offset <= len; }  // fixext 4
        if (tag == 0xD7) { offset += 9; return offset <= len; }  // fixext 8
        if (tag == 0xD8) { offset += 17; return offset <= len; } // fixext 16

        // Unknown tag
        return false;
    }

    // Pack a msgpack bin (binary) into a buffer. Returns bytes written.
    // LXMF reference implementation uses bin type for title and content.
    inline size_t pack_bin(uint8_t* buf, size_t buflen, const uint8_t* data, size_t dlen) {
        size_t pos = 0;

        if (dlen <= 255) {
            if (pos + 2 + dlen > buflen) return 0;
            buf[pos++] = 0xC4;  // bin 8
            buf[pos++] = (uint8_t)dlen;
        } else {
            if (pos + 3 + dlen > buflen) return 0;
            buf[pos++] = 0xC5;  // bin 16
            buf[pos++] = (dlen >> 8) & 0xFF;
            buf[pos++] = dlen & 0xFF;
        }

        memcpy(&buf[pos], data, dlen);
        pos += dlen;
        return pos;
    }

    // Convenience: pack a std::string as msgpack bin
    inline size_t pack_bin_str(uint8_t* buf, size_t buflen, const std::string& str) {
        return pack_bin(buf, buflen, (const uint8_t*)str.c_str(), str.length());
    }

    // Pack a msgpack string into a buffer. Returns bytes written.
    // NOTE: Only use for non-LXMF fields. LXMF title/content use pack_bin.
    inline size_t pack_string(uint8_t* buf, size_t buflen, const std::string& str) {
        size_t slen = str.length();
        size_t pos = 0;

        if (slen <= 31) {
            if (pos + 1 + slen > buflen) return 0;
            buf[pos++] = 0xA0 | (uint8_t)slen;  // fixstr
        } else if (slen <= 255) {
            if (pos + 2 + slen > buflen) return 0;
            buf[pos++] = 0xD9;  // str 8
            buf[pos++] = (uint8_t)slen;
        } else {
            if (pos + 3 + slen > buflen) return 0;
            buf[pos++] = 0xDA;  // str 16
            buf[pos++] = (slen >> 8) & 0xFF;
            buf[pos++] = slen & 0xFF;
        }

        memcpy(&buf[pos], str.c_str(), slen);
        pos += slen;
        return pos;
    }

    // Pack a float64 (double) timestamp
    inline size_t pack_float64(uint8_t* buf, size_t buflen, double val) {
        if (buflen < 9) return 0;
        buf[0] = 0xCB;  // float64
        uint64_t bits;
        memcpy(&bits, &val, 8);
        // Big-endian
        for (int i = 7; i >= 0; i--) {
            buf[8 - i] = (bits >> (i * 8)) & 0xFF;
        }
        return 9;
    }

    // Pack a bool: true (0xC3) or false (0xC2)
    inline size_t pack_bool(uint8_t* buf, size_t buflen, bool val) {
        if (buflen < 1) return 0;
        buf[0] = val ? 0xC3 : 0xC2;
        return 1;
    }

    // Pack nil (0xC0)
    inline size_t pack_nil(uint8_t* buf, size_t buflen) {
        if (buflen < 1) return 0;
        buf[0] = 0xC0;
        return 1;
    }

    // Pack a positive fixint (0-127), used for msgpack integer keys like SIDs
    inline size_t pack_fixint(uint8_t* buf, size_t buflen, uint8_t val) {
        if (buflen < 1 || val > 127) return 0;
        buf[0] = val;
        return 1;
    }

    // Pack a float32 (big-endian)
    inline size_t pack_float32(uint8_t* buf, size_t buflen, float val) {
        if (buflen < 5) return 0;
        buf[0] = 0xCA;  // float32
        uint32_t bits;
        memcpy(&bits, &val, 4);
        buf[1] = (bits >> 24) & 0xFF;
        buf[2] = (bits >> 16) & 0xFF;
        buf[3] = (bits >> 8) & 0xFF;
        buf[4] = bits & 0xFF;
        return 5;
    }

    // Pack a uint32 (big-endian)
    inline size_t pack_uint32(uint8_t* buf, size_t buflen, uint32_t val) {
        if (buflen < 5) return 0;
        buf[0] = 0xCE;  // uint32
        buf[1] = (val >> 24) & 0xFF;
        buf[2] = (val >> 16) & 0xFF;
        buf[3] = (val >> 8) & 0xFF;
        buf[4] = val & 0xFF;
        return 5;
    }

} // namespace RawMsgPack


// ============================================================================
// Sideband Telemeter battery payload builder
// Builds: msgpack({ 0x01: timestamp_uint32, 0x04: [percent, charging, null] })
// ============================================================================

// Forward declarations for battery globals (defined in Config.h)
extern float    battery_voltage;
extern float    battery_percent;
extern uint8_t  battery_state;
extern bool     battery_ready;

#ifndef BATTERY_STATE_CHARGING
#define BATTERY_STATE_CHARGING 0x02  // match Config.h
#endif

static size_t pack_battery_telemeter(uint8_t* buf, size_t buflen, uint32_t timestamp) {
    if (buflen < 20) return 0;
    size_t pos = 0;
    size_t n;

    // fixmap(2): two entries (SID_TIME + SID_BATTERY)
    buf[pos++] = 0x82;

    // Key: SID_TIME (0x01)
    n = RawMsgPack::pack_fixint(&buf[pos], buflen - pos, 0x01);
    if (n == 0) return 0; pos += n;

    // Value: uint32 timestamp
    n = RawMsgPack::pack_uint32(&buf[pos], buflen - pos, timestamp);
    if (n == 0) return 0; pos += n;

    // Key: SID_BATTERY (0x04)
    n = RawMsgPack::pack_fixint(&buf[pos], buflen - pos, 0x04);
    if (n == 0) return 0; pos += n;

    // Value: fixarray(3) [charge_percent, charging_bool, null]
    buf[pos++] = 0x93;  // fixarray(3)

    // charge_percent as float32, rounded to 1 decimal
    float pct = roundf(battery_percent * 10.0f) / 10.0f;
    n = RawMsgPack::pack_float32(&buf[pos], buflen - pos, pct);
    if (n == 0) return 0; pos += n;

    // charging: true if battery_state == CHARGING
    n = RawMsgPack::pack_bool(&buf[pos], buflen - pos, battery_state == BATTERY_STATE_CHARGING);
    if (n == 0) return 0; pos += n;

    // temperature: null
    n = RawMsgPack::pack_nil(&buf[pos], buflen - pos);
    if (n == 0) return 0; pos += n;

    return pos;
}

// ============================================================================
// LXMFMinimal class
// ============================================================================

class LXMFMinimal {
public:
    // Message handler callback: (source_hash_16bytes, content_string) -> reply_string
    using MessageHandler = std::function<std::string(const uint8_t* source_hash, const std::string& content)>;

    LXMFMinimal() : _identity(RNS::Type::NONE),
                     _destination(RNS::Type::NONE),
                     _initialized(false),
                     _last_announce(0),
                     _announce_interval(300000),  // 5 minutes
                     _time_offset(0),
                     _time_calibrated(false),
                     _display_name("LXMF Node"),
                     _handler(nullptr) {}

    // ---- Static callback glue ----
    // microReticulum uses plain function pointers, not std::function.
    static LXMFMinimal* _instance;

    static void _static_packet_callback(const RNS::Bytes& data, const RNS::Packet& packet) {
        if (_instance) {
            _instance->_on_packet(data, packet);
        }
    }

    // ---- Init ----
    bool init(RNS::Identity& identity, const char* display_name = "LXMF Node") {
        _identity = identity;
        _display_name = display_name;

        // Register static instance for callback routing
        _instance = this;

        // Create LXMF delivery destination: "lxmf.delivery"
        _destination = RNS::Destination(
            _identity,
            RNS::Type::Destination::IN,
            RNS::Type::Destination::SINGLE,
            "lxmf", "delivery"
        );

        // Set packet callback (plain function pointer)
        _destination.set_packet_callback(_static_packet_callback);

        // Print address
        std::string addr = _destination.hash().toHex();
        Serial.print("[LXMF] Delivery destination ready: ");
        Serial.println(addr.c_str());

        _initialized = true;

        // Initial announce
        announce();

        return true;
    }

    // ---- Set message handler ----
    void set_message_handler(MessageHandler handler) {
        _handler = handler;
    }

    // ---- Announce ----
    void announce() {
        if (!_initialized) return;

        // Reference format (LXMRouter.py get_announce_app_data):
        //   peer_data = [display_name.encode("utf-8"), stamp_cost]
        //   return msgpack.packb(peer_data)
        uint8_t announce_buf[128];
        size_t pos = 0;

        // fixarray(2)
        announce_buf[pos++] = 0x92;

        // display_name as bin type (matching Python bytes behavior)
        size_t name_written = RawMsgPack::pack_bin(
            &announce_buf[pos], sizeof(announce_buf) - pos,
            (const uint8_t*)_display_name.c_str(), _display_name.length());
        if (name_written == 0) { Serial.println("[LXMF] Announce: name pack failed"); return; }
        pos += name_written;

        // stamp_cost: nil (no stamp required)
        announce_buf[pos++] = 0xC0;

        RNS::Bytes app_data(announce_buf, pos);
        _destination.announce(app_data);

        _last_announce = millis();
        Serial.println("[LXMF] Announced delivery destination");
    }

    // ---- Loop (call from main loop) ----
    void loop() {
        if (!_initialized) return;

        // Periodic re-announce
        unsigned long now = millis();
        if (now - _last_announce >= _announce_interval) {
            announce();
        }
    }

    // ---- Get LXMF address as hex string ----
    std::string get_address() {
        if (!_initialized) return "";
        return _destination.hash().toHex();
    }

    // ---- Time estimation ----
    // ESP32 has no RTC/NTP in LoRa-only mode. We estimate Unix epoch time:
    //   1. Start with compile-time as a baseline (guaranteed to be in the past)
    //   2. Calibrate from the first valid incoming LXMF message timestamp
    //   3. Advance by millis() delta from calibration point
    double get_timestamp() {
        double uptime_sec = (double)(millis()) / 1000.0;
        if (_time_calibrated) {
            return _time_offset + uptime_sec;
        }
        // Fallback: compile-time epoch + uptime
        // __DATE__ and __TIME__ give compile time; approximate as constant
        // This ensures timestamps are at least in the right year
        return _compile_time_epoch() + uptime_sec;
    }

    void calibrate_time(double remote_timestamp) {
        // Only calibrate from plausible timestamps (after 2024-01-01)
        if (remote_timestamp > 1704067200.0 && !_time_calibrated) {
            double uptime_sec = (double)(millis()) / 1000.0;
            _time_offset = remote_timestamp - uptime_sec;
            _time_calibrated = true;
            Serial.print("[LXMF] Time calibrated from peer, epoch offset: ");
            Serial.println((long)_time_offset);
        }
    }

    // ---- Set announce interval ----
    void set_announce_interval(unsigned long ms) { _announce_interval = ms; }
    unsigned long get_announce_interval() const { return _announce_interval; }

    // ---- Send reply ----
    void send_reply(const uint8_t* dest_hash, const std::string& content,
                    const uint8_t* telemetry_data = nullptr, size_t telemetry_len = 0) {
        if (!_initialized) return;

        // Look up the sender's identity from cache
        RNS::Bytes dest_hash_bytes(dest_hash, LXMF_HASH_LEN);
        RNS::Identity remote_identity = RNS::Identity::recall(dest_hash_bytes);

        if (!remote_identity) {
            Serial.println("[LXMF] Cannot reply: sender identity not known (not announced?)");
            return;
        }

        // Create outbound destination for sender's lxmf.delivery
        RNS::Destination remote_dest(
            remote_identity,
            RNS::Type::Destination::OUT,
            RNS::Type::Destination::SINGLE,
            "lxmf", "delivery"
        );

        // ---- Step 1: Build msgpack payload ----
        // Reference: payload = [timestamp, title, content, fields]
        // title and content are bin type, fields is nil
        uint8_t msgpack_buf[512];
        size_t pos = 0;

        // fixarray of 4 elements
        msgpack_buf[pos++] = 0x94;

        // timestamp as float64
        double timestamp = get_timestamp();
        size_t ts_len = RawMsgPack::pack_float64(&msgpack_buf[pos], sizeof(msgpack_buf) - pos, timestamp);
        if (ts_len == 0) { Serial.println("[LXMF] Reply: timestamp pack failed"); return; }
        pos += ts_len;

        // title: empty bin (0xC4 0x00)
        size_t title_len = RawMsgPack::pack_bin(&msgpack_buf[pos], sizeof(msgpack_buf) - pos,
                                                 (const uint8_t*)"", 0);
        if (title_len == 0) { Serial.println("[LXMF] Reply: title pack failed"); return; }
        pos += title_len;

        // content: bin type
        size_t content_len = RawMsgPack::pack_bin_str(&msgpack_buf[pos], sizeof(msgpack_buf) - pos, content);
        if (content_len == 0) { Serial.println("[LXMF] Reply: content pack failed"); return; }
        pos += content_len;

        // fields: nil or {0x02: bin(telemetry_data)}
        if (telemetry_data && telemetry_len > 0) {
            // fixmap(1)
            msgpack_buf[pos++] = 0x81;
            // key: FIELD_TELEMETRY (0x02)
            size_t k = RawMsgPack::pack_fixint(&msgpack_buf[pos], sizeof(msgpack_buf) - pos, 0x02);
            if (k == 0) { Serial.println("[LXMF] Reply: telemetry key pack failed"); return; }
            pos += k;
            // value: bin(telemetry payload)
            size_t v = RawMsgPack::pack_bin(&msgpack_buf[pos], sizeof(msgpack_buf) - pos,
                                             telemetry_data, telemetry_len);
            if (v == 0) { Serial.println("[LXMF] Reply: telemetry data pack failed"); return; }
            pos += v;
        } else {
            msgpack_buf[pos++] = 0xC0;  // nil
        }

        // ---- Step 2: Compute signature ----
        // Reference (LXMessage.py pack()):
        //   hashed_part  = destination_hash + source_hash + packed_payload
        //   message_hash = SHA256(hashed_part)
        //   signed_part  = hashed_part + message_hash
        //   signature    = source_identity.sign(signed_part)
        const RNS::Bytes& our_hash = _destination.hash();
        const RNS::Bytes& their_hash = remote_dest.hash();

        RNS::Bytes hashed_part;
        hashed_part.append(their_hash.data(), LXMF_HASH_LEN);  // destination
        hashed_part.append(our_hash.data(), LXMF_HASH_LEN);    // source
        hashed_part.append(msgpack_buf, pos);                    // packed_payload

        RNS::Bytes message_hash = RNS::Identity::full_hash(hashed_part);

        RNS::Bytes signed_part;
        signed_part.append(hashed_part);
        signed_part.append(message_hash);

        RNS::Bytes signature;
        try {
            signature = _identity.sign(signed_part);
        } catch (const std::exception& e) {
            Serial.print("[LXMF] Reply: signing failed: ");
            Serial.println(e.what());
        }
        if (signature.size() != LXMF_SIG_LEN) {
            if (signature.size() > 0) {
                Serial.print("[LXMF] Reply: unexpected signature length: ");
                Serial.println(signature.size());
            }
            // Fall back to zeros — message will be "unverified" but still delivered
            uint8_t zeros[LXMF_SIG_LEN] = {0};
            signature = RNS::Bytes(zeros, LXMF_SIG_LEN);
        }

        // ---- Step 3: Build LXMF packet data ----
        // Opportunistic format: source_hash(16) + signature(64) + packed_payload
        // (destination_hash is implied by the RNS packet destination)
        size_t total_len = LXMF_HASH_LEN + LXMF_SIG_LEN + pos;
        if (total_len > 450) {
            Serial.println("[LXMF] Reply: payload too large");
            return;
        }

        uint8_t lxmf_data[450];
        size_t lxmf_pos = 0;

        // Our source hash
        memcpy(&lxmf_data[lxmf_pos], our_hash.data(), LXMF_HASH_LEN);
        lxmf_pos += LXMF_HASH_LEN;

        // Ed25519 signature
        memcpy(&lxmf_data[lxmf_pos], signature.data(), LXMF_SIG_LEN);
        lxmf_pos += LXMF_SIG_LEN;

        // Msgpack payload
        memcpy(&lxmf_data[lxmf_pos], msgpack_buf, pos);
        lxmf_pos += pos;

        // Send as RNS packet
        RNS::Bytes packet_data(lxmf_data, lxmf_pos);
        RNS::Packet packet(remote_dest, packet_data);
        packet.send();

        Serial.print("[LXMF] Reply sent to ");
        Serial.println(dest_hash_bytes.toHex().c_str());
    }

private:
    RNS::Identity     _identity;
    RNS::Destination  _destination;
    bool              _initialized;
    unsigned long     _last_announce;
    unsigned long     _announce_interval;
    std::string       _display_name;
    MessageHandler    _handler;
    double            _time_offset;       // Epoch offset: epoch_time = _time_offset + millis()/1000
    bool              _time_calibrated;   // True once calibrated from a peer's timestamp

    // Approximate compile-time as Unix epoch (rough, but better than 0)
    static double _compile_time_epoch() {
        // __DATE__ = "Feb 22 2026", __TIME__ = "12:00:00"
        // Use a rough estimate: seconds since 2025-01-01 as baseline
        // 2025-01-01 00:00:00 UTC = 1735689600
        // This is deliberately conservative - just needs to be in the right decade
        return 1735689600.0;
    }

    // ---- Packet receive handler ----
    void _on_packet(const RNS::Bytes& data, const RNS::Packet& packet) {
        Serial.print("[LXMF] Received packet, ");
        Serial.print(data.size());
        Serial.println(" bytes");

        // Send delivery proof back to sender.
        // Reference: LXMRouter.delivery_packet() calls packet.prove() first.
        // Without this, sender (Sideband) shows message as "undelivered".
        const_cast<RNS::Packet&>(packet).prove();

        // Minimum LXMF payload: source_hash(16) + signature(64) + minimal_msgpack(~5)
        if (data.size() < LXMF_HEADER_LEN + 5) {
            Serial.println("[LXMF] Packet too short for LXMF");
            return;
        }

        const uint8_t* raw = data.data();
        size_t raw_len = data.size();

        // Extract source hash (first 16 bytes)
        uint8_t source_hash[LXMF_HASH_LEN];
        memcpy(source_hash, raw, LXMF_HASH_LEN);

        // Skip signature (next 64 bytes) — we don't verify

        // Parse msgpack payload starting after header
        const uint8_t* payload = raw + LXMF_HEADER_LEN;
        size_t payload_len = raw_len - LXMF_HEADER_LEN;

        // Parse: array[timestamp, title, content, fields]
        double msg_timestamp = 0;
        std::string content = _parse_lxmf_content(payload, payload_len, &msg_timestamp);

        // Calibrate our clock from the sender's timestamp
        if (msg_timestamp > 0) {
            calibrate_time(msg_timestamp);
        }

        if (content.empty()) {
            Serial.println("[LXMF] Failed to parse message content");
            return;
        }

        RNS::Bytes src_bytes(source_hash, LXMF_HASH_LEN);
        Serial.print("[LXMF] Message from ");
        Serial.print(src_bytes.toHex().c_str());
        Serial.print(": ");
        Serial.println(content.c_str());

        // Route to handler
        if (_handler) {
            std::string reply = _handler(source_hash, content);
            if (!reply.empty()) {
                // Attach battery telemetry if available
                uint8_t telem_buf[32];
                size_t telem_len = 0;
                if (battery_ready) {
                    telem_len = pack_battery_telemeter(telem_buf, sizeof(telem_buf),
                                                       (uint32_t)get_timestamp());
                    if (telem_len == 0) {
                        Serial.println("[LXMF] Reply: telemetry pack failed");
                    }
                }
                send_reply(source_hash, reply,
                           telem_len > 0 ? telem_buf : nullptr, telem_len);
            }
        }
    }

    // ---- Parse LXMF msgpack to extract content (3rd element of array) ----
    // Optionally extracts timestamp (1st element) for clock calibration
    std::string _parse_lxmf_content(const uint8_t* data, size_t len, double* out_timestamp = nullptr) {
        if (len < 2) return "";

        size_t offset = 0;
        uint8_t tag = data[offset++];

        // Expect array
        size_t arr_len = 0;
        if ((tag & 0xF0) == 0x90) {
            arr_len = tag & 0x0F;
        } else if (tag == 0xDC && offset + 1 < len) {
            arr_len = (data[offset] << 8) | data[offset + 1];
            offset += 2;
        } else {
            Serial.print("[LXMF] Expected array, got tag 0x");
            Serial.println(tag, HEX);
            return "";
        }

        if (arr_len < 3) {
            Serial.println("[LXMF] Array too short (need >= 3 elements)");
            return "";
        }

        // Element 0: timestamp — extract if requested, then advance past it
        if (out_timestamp && offset < len) {
            uint8_t ts_tag = data[offset];
            if (ts_tag == 0xCB && offset + 8 < len) {
                // float64 big-endian → little-endian double via byte reversal
                union { double d; uint8_t b[8]; } u;
                for (int i = 0; i < 8; i++) u.b[7 - i] = data[offset + 1 + i];
                *out_timestamp = u.d;
            }
        }
        if (!RawMsgPack::skip_element(data, len, offset)) {
            Serial.println("[LXMF] Failed to skip timestamp");
            return "";
        }

        // Element 1: title — skip it
        if (!RawMsgPack::skip_element(data, len, offset)) {
            Serial.println("[LXMF] Failed to skip title");
            return "";
        }

        // Element 2: content — read as string (handles both bin and str types)
        return RawMsgPack::read_bin_or_str(data, len, offset);
    }
};

// Static instance pointer definition
LXMFMinimal* LXMFMinimal::_instance = nullptr;

#endif // LXMF_MINIMAL_H
