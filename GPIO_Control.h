// GPIO_Control.h — LXMF-based remote control for microReticulum transport nodes
// Receives text commands via LXMF messages, returns status.
//
// Commands (case-insensitive):
//   BATTERY              — Report battery voltage, percent, and charging state
//   ANNOUNCE [min]       — Show or set announce interval (1-1440 min)
//   HELP                 — Show command list

#ifndef GPIO_CONTROL_H
#define GPIO_CONTROL_H

#ifdef HAS_RNS

#include "LXMF_Minimal.h"
#include <Arduino.h>
#include <string>
#include <vector>
#include <algorithm>

// ─── Helpers ────────────────────────────────────────────────────

static std::string str_upper(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), ::toupper);
    return s;
}

static std::string str_trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    size_t b = s.find_last_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    return s.substr(a, b - a + 1);
}

static std::vector<std::string> tokenize(const std::string& s) {
    std::vector<std::string> t;
    std::string tok;
    for (char c : s) {
        if (c == ' ' || c == '\t') {
            if (!tok.empty()) { t.push_back(tok); tok.clear(); }
        } else { tok += c; }
    }
    if (!tok.empty()) t.push_back(tok);
    return t;
}

// Global LXMF pointer for use in ANNOUNCE command (set during GPIOControl::init)
static LXMFMinimal* g_lxmf = nullptr;

// ─── Command Handler ────────────────────────────────────────────

static std::string handle_command(const std::string& raw_command) {
    std::string cmd = str_trim(raw_command);
    if (cmd.empty()) return "ERR: Empty command";

    auto tokens = tokenize(str_upper(cmd));
    if (tokens.empty()) return "ERR: Empty command";
    std::string verb = tokens[0];

    // ── HELP ──
    if (verb == "HELP" || verb == "?") {
        return "Commands:\n"
               "BATTERY\n"
               "ANNOUNCE [min]\n"
               "HELP";
    }

    // ── BATTERY ──
    if (verb == "BATTERY" || verb == "BAT") {
        if (!battery_ready) return "Battery: not available";
        const char* state_str = "unknown";
        if (battery_state == 0x01) state_str = "discharging";
        else if (battery_state == 0x02) state_str = "charging";
        else if (battery_state == 0x03) state_str = "charged";
        char buf[64];
        snprintf(buf, sizeof(buf), "Battery: %.2fV  %.1f%%  %s",
                 battery_voltage, battery_percent, state_str);
        return std::string(buf);
    }

    // ── ANNOUNCE ──
    if (verb == "ANNOUNCE" || verb == "ANN") {
        extern unsigned long transport_announce_interval;
        if (tokens.size() < 2) {
            // Report current intervals
            unsigned long lxmf_min = 0;
            unsigned long transport_min = transport_announce_interval / 60000;
            if (g_lxmf) {
                lxmf_min = g_lxmf->get_announce_interval() / 60000;
            }
            char buf[80];
            snprintf(buf, sizeof(buf), "Announce: LXMF %lu min, Transport %lu min",
                     lxmf_min, transport_min);
            return std::string(buf);
        }
        int minutes = 0;
        try { minutes = std::stoi(tokens[1]); }
        catch (...) { return "ERR: Bad number: " + tokens[1]; }
        if (minutes < 1 || minutes > 1440) return "ERR: Range 1-1440 min";
        unsigned long ms = (unsigned long)minutes * 60000UL;
        if (g_lxmf) {
            g_lxmf->set_announce_interval(ms);
        }
        transport_announce_interval = ms;
        char buf[48];
        snprintf(buf, sizeof(buf), "OK Announce interval: %d min", minutes);
        return std::string(buf);
    }

    return "ERR: Unknown: " + verb + " (try HELP)";
}

// ─── Node Control Manager ───────────────────────────────────────

class GPIOControl {
public:
    static GPIOControl* _instance;

    GPIOControl() : _initialized(false) {}

    bool init(RNS::Identity& identity, const char* display_name = "LXMF Node") {
        Serial.println("[GPIO] Initializing...");
        _instance = this;

        if (!_lxmf.init(identity, display_name)) {
            Serial.println("[GPIO] LXMF init failed");
            return false;
        }

        // Set global LXMF pointer for command handlers
        g_lxmf = &_lxmf;

        // Register message handler
        _lxmf.set_message_handler(GPIOControl::on_lxmf_message);

        _initialized = true;

        Serial.println("[GPIO] Ready!");
        Serial.print("[GPIO] LXMF address: ");
        Serial.println(_lxmf.get_address().c_str());

        return true;
    }

    void loop() {
        if (!_initialized) return;
        _lxmf.loop();
    }

    std::string get_address() { return _lxmf.get_address(); }
    LXMFMinimal& lxmf() { return _lxmf; }

private:
    static std::string on_lxmf_message(const uint8_t* source_hash, const std::string& content) {
        if (!_instance) return "ERR: not initialized";

        Serial.print("[GPIO] Command: ");
        Serial.println(content.c_str());

        std::string response = handle_command(content);
        Serial.print("[GPIO] Response: ");
        Serial.println(response.c_str());

        return response;
    }

    LXMFMinimal _lxmf;
    bool        _initialized;
};

// Static instance pointer
GPIOControl* GPIOControl::_instance = nullptr;

#endif  // HAS_RNS
#endif  // GPIO_CONTROL_H
