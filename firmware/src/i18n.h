// aihelper 固件 2.0：三种语言的固定文字
#pragma once
#include <Arduino.h>

enum Lang { L_ZH, L_JA, L_EN };
enum Str {
  S_APPROVAL, S_QUESTION, S_DONE, S_ERROR, S_NOTE,
  S_ONLY_LEFT, S_STALE_T, S_STALE_S, S_LONG_AGO,
  S_OFF_T, S_OFF_S, S_REST_T, S_REST_S, S_CONNECTING,
  S_NOLINK_T, S_NOLINK_S, S_NOLINK_S2,
  S_PAT_ACK, S_TAP_ACK, S_WAITED, S_MORE, S_N_WAITING,
  S_ALL, S_ALL_USED, S_SYNCED, S_USED, S_LEFT, S_STALE_DATA, S_TAP_BACK, S_CANT_READ, S_UNUSED,
  S_UPDATING, S_KEEP_POWER, S_UPDATE_FAIL, S_UPDATE_FAIL_S,
  S_SETUP_T, S_SETUP_1A, S_SETUP_1B, S_SETUP_2A, S_SETUP_2B, S_SETUP_2C, S_SETUP_3, S_SETUP_4,
  S_RESTORED,
  S_COUNT
};
void i18nSet(const String& lang);
Lang i18nLang();
const char* tr(Str k);
String trf(Str k, ...);
