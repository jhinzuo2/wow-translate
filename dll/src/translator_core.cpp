// translator_core.cpp - Translation functionality for WoWTranslate
// Sends GET requests to translate.googleapis.com (client=gtx) — no API key required

#include <windows.h>
#include <winhttp.h>
#include <string>
#include <algorithm>
#include <sstream>
#include <iomanip>
#include <codecvt>
#include <locale>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <ctime>

#include "../include/translator_core.h"
#include "../include/logging.h"
#include "../include/utils.h"

using namespace std;

// UTF-8 codepoint encoder (file-scope for use in multiple places)
static string ConvertCodepointToUTF8(unsigned int codepoint) {
    string result;
    if (codepoint <= 0x7F) {
        result += static_cast<char>(codepoint);
    } else if (codepoint <= 0x7FF) {
        result += static_cast<char>(0xC0 | (codepoint >> 6));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    } else if (codepoint <= 0xFFFF) {
        result += static_cast<char>(0xE0 | (codepoint >> 12));
        result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    } else if (codepoint <= 0x10FFFF) {
        result += static_cast<char>(0xF0 | (codepoint >> 18));
        result += static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F));
        result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    }
    return result;
}

// Simple JSON parser for proxy server responses
class SimpleJsonParser {
public:
    static string extractField(const string& json, const string& fieldName) {
        string searchKey = "\"" + fieldName + "\"";
        size_t keyPos = json.find(searchKey);
        if (keyPos == string::npos) {
            return "";
        }

        size_t colonPos = json.find(":", keyPos + searchKey.length());
        if (colonPos == string::npos) {
            return "";
        }

        size_t start = colonPos + 1;
        while (start < json.length() && (json[start] == ' ' || json[start] == '\t' || json[start] == '\n' || json[start] == '\r')) {
            start++;
        }

        if (start >= json.length()) {
            return "";
        }

        // Check if it's a string value (starts with quote)
        if (json[start] == '"') {
            start++;
            size_t end = start;
            while (end < json.length() && json[end] != '"') {
                if (json[end] == '\\' && end + 1 < json.length()) {
                    end += 2; // Skip escaped character
                } else {
                    end++;
                }
            }
            return unescapeJson(json.substr(start, end - start));
        }

        // It's a number or boolean
        size_t end = start;
        while (end < json.length() && json[end] != ',' && json[end] != '}' && json[end] != '\n') {
            end++;
        }
        string value = json.substr(start, end - start);
        // Trim whitespace
        while (!value.empty() && (value.back() == ' ' || value.back() == '\t' || value.back() == '\r')) {
            value.pop_back();
        }
        return value;
    }

    static double extractNumber(const string& json, const string& fieldName) {
        string value = extractField(json, fieldName);
        if (value.empty()) return -1;
        try {
            return stod(value);
        } catch (...) {
            return -1;
        }
    }

private:
    static string unescapeJson(const string& input) {
        string result = input;
        size_t pos = 0;

        // Unescape basic characters
        while ((pos = result.find("\\\"", pos)) != string::npos) {
            result.replace(pos, 2, "\"");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\\\", pos)) != string::npos) {
            result.replace(pos, 2, "\\");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\n", pos)) != string::npos) {
            result.replace(pos, 2, "\n");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\r", pos)) != string::npos) {
            result.replace(pos, 2, "\r");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\t", pos)) != string::npos) {
            result.replace(pos, 2, "\t");
            pos += 1;
        }

        // Handle Unicode escape sequences \uXXXX
        pos = 0;
        while ((pos = result.find("\\u", pos)) != string::npos) {
            if (pos + 5 < result.length()) {
                string hexStr = result.substr(pos + 2, 4);
                try {
                    unsigned int codepoint = stoul(hexStr, nullptr, 16);
                    string utf8_char = ConvertCodepointToUTF8(codepoint);
                    result.replace(pos, 6, utf8_char);
                    pos += utf8_char.length();
                } catch (...) {
                    pos += 6;
                }
            } else {
                break;
            }
        }

        return result;
    }
};

// Global variables
unique_ptr<TranslationClient> g_translator = nullptr;
char g_translation_buffer[4096] = {0};
char g_error_buffer[256] = {0};

TranslationClient::TranslationClient()
    : hSession(nullptr), hConnect(nullptr), initialized(false), running(false) {
}

TranslationClient::~TranslationClient() {
    Cleanup();
}

bool TranslationClient::Initialize() {
    if (initialized) Cleanup();

    const std::string host = "translate.googleapis.com";
    const int port = 443;

    LOG_INFO("Initializing Google Free translation client");

    // Seed jitter for backoff randomness
    srand((unsigned)time(nullptr));

    // NOTE: The session-level "product name" here doubles as the default
    // User-Agent for every request on this session unless a request
    // explicitly overrides it. Using a self-identifying string like
    // "WoWTranslate/1.0" flags this as a non-browser client to Google's
    // abuse detection on the undocumented gtx endpoint, which can trigger
    // 429s almost immediately. Use a realistic browser UA here so any
    // request that (for whatever reason) doesn't get its per-request
    // override still looks like ordinary browser traffic.
    hSession = WinHttpOpen(
        L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        L"(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);
    if (!hSession) {
        LOG_ERROR("Failed to initialize WinHTTP session");
        return false;
    }

    // 8-second timeouts so a blocked/unreachable endpoint fails fast
    WinHttpSetTimeouts(hSession, 8000, 8000, 8000, 8000);

    wstring wHost(host.begin(), host.end());
    hConnect = WinHttpConnect(hSession, wHost.c_str(),
                              static_cast<INTERNET_PORT>(port), 0);
    if (!hConnect) {
        LOG_ERROR("Failed to connect to translate.googleapis.com");
        WinHttpCloseHandle(hSession);
        hSession = nullptr;
        return false;
    }

    running = true;
    workerThread = thread(&TranslationClient::WorkerThreadFunc, this);
    initialized = true;
    LOG_INFO("Google Free translation client initialized");
    return true;
}


void TranslationClient::Cleanup() {
    // Stop worker thread
    if (running) {
        running = false;
        if (workerThread.joinable()) {
            workerThread.join();
        }
    }

    if (hConnect) {
        WinHttpCloseHandle(hConnect);
        hConnect = nullptr;
    }

    if (hSession) {
        WinHttpCloseHandle(hSession);
        hSession = nullptr;
    }

    cache.clear();
    initialized = false;
    LOG_INFO("Translation client cleanup complete");
}

string TranslationClient::UrlEncode(const string& text) {
    ostringstream encoded;
    encoded.fill('0');
    encoded << hex;

    for (unsigned char c : text) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            encoded << c;
        } else {
            encoded << uppercase;
            encoded << '%' << setw(2) << static_cast<int>(c);
            encoded << nouppercase;
        }
    }

    return encoded.str();
}

string TranslationClient::GenerateCacheKey(const string& text, const string& sourceLang, const string& targetLang) {
    return sourceLang + "->" + targetLang + ":" + text;
}

void TranslationClient::CleanExpiredCache() {
    DWORD currentTime = GetTickCount();
    auto it = cache.begin();

    while (it != cache.end()) {
        if (currentTime - it->second.timestamp > CACHE_EXPIRY_MS) {
            it = cache.erase(it);
        } else {
            ++it;
        }
    }

    if (cache.size() > MAX_CACHE_SIZE) {
        size_t removeCount = cache.size() - MAX_CACHE_SIZE / 2;
        for (size_t i = 0; i < removeCount && !cache.empty(); ++i) {
            cache.erase(cache.begin());
        }
    }
}

string TranslationClient::MapLangCode(const string& lang) {
    if (lang == "zh") return "zh-CN";
    // ja, ko, ru, en are already valid Google lang codes
    return lang;
}

// Updated HttpsGet: adds realistic browser headers and simple exponential-backoff retries.
// Note: we do NOT add Accept-Encoding here to avoid needing decompression; if you add it,
// implement decompression (gzip/deflate/br) or enable WinHTTP decompression options.
string TranslationClient::HttpsGet(const string& path) {
    if (!hConnect) return "";

    wstring wPath(path.begin(), path.end());

    const int maxRetries = 4;
    int attempt = 0;
    int backoffMs = 500; // initial backoff

    while (attempt < maxRetries) {
        attempt++;

        HINTERNET hRequest = WinHttpOpenRequest(
            hConnect, L"GET", wPath.c_str(), nullptr,
            WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
            WINHTTP_FLAG_SECURE);

        if (!hRequest) {
            LOG_ERROR("Failed to open GET request");
            return "";
        }

        // More realistic browser headers to reduce fingerprinting
        wstring headers =
            L"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            L"AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36\r\n"
            L"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8\r\n"
            L"Accept-Language: en-US,en;q=0.9\r\n"
            // Do NOT add Accept-Encoding here unless you implement decompression below.
            L"Referer: https://translate.google.com/\r\n"
            L"Origin: https://translate.google.com\r\n"
            L"Connection: keep-alive\r\n";

        WinHttpAddRequestHeaders(hRequest, headers.c_str(), (DWORD)-1,
                                 WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

        BOOL result = WinHttpSendRequest(hRequest,
                                         WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                         nullptr, 0, 0, 0);

        string response;
        if (result && WinHttpReceiveResponse(hRequest, nullptr)) {
            // Read HTTP status code before consuming the body.
            DWORD statusCode = 0;
            DWORD statusLen  = sizeof(DWORD);
            WinHttpQueryHeaders(hRequest,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                WINHTTP_HEADER_NAME_BY_INDEX,
                &statusCode, &statusLen,
                WINHTTP_NO_HEADER_INDEX);

            if (statusCode == 429) {
                LOG_WARNING("Rate limited by Google (HTTP 429) on attempt " + to_string(attempt));

                // Try to read Retry-After header (if present) and respect it
                DWORD headerSize = 0;
                if (!WinHttpQueryHeaders(hRequest,
                        WINHTTP_QUERY_RETRY_AFTER,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        nullptr, &headerSize, WINHTTP_NO_HEADER_INDEX)) {
                    if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && headerSize > 0) {
                        std::vector<wchar_t> buf(headerSize / sizeof(wchar_t) + 1);
                        if (WinHttpQueryHeaders(hRequest,
                                WINHTTP_QUERY_RETRY_AFTER,
                                WINHTTP_HEADER_NAME_BY_INDEX,
                                buf.data(), &headerSize, WINHTTP_NO_HEADER_INDEX)) {
                            wstring wRetry(buf.data());
                            int secs = _wtoi(wRetry.c_str());
                            if (secs > 0) {
                                WinHttpCloseHandle(hRequest);
                                Sleep(secs * 1000);
                                // If this was the last attempt, return HTTP_429 so caller can back off permanently
                                if (attempt >= maxRetries) return "HTTP_429";
                                backoffMs *= 2;
                                continue;
                            }
                        }
                    }
                }

                WinHttpCloseHandle(hRequest);

                if (attempt >= maxRetries) {
                    return "HTTP_429";
                }

                // Exponential backoff with small jitter
                int jitter = rand() % 200; // 0..199 ms
                Sleep(backoffMs + jitter);
                backoffMs *= 2;
                continue;
            }

            DWORD bytesAvailable = 0;
            char buffer[8192];
            while (WinHttpQueryDataAvailable(hRequest, &bytesAvailable)
                   && bytesAvailable > 0) {
                DWORD bytesRead = 0;
                DWORD bytesToRead = min(bytesAvailable, (DWORD)(sizeof(buffer) - 1));
                if (WinHttpReadData(hRequest, buffer, bytesToRead, &bytesRead)) {
                    buffer[bytesRead] = '\0';
                    response += string(buffer, bytesRead);
                } else {
                    break;
                }
            }

            WinHttpCloseHandle(hRequest);

            // Success: return response (may be empty if server sent empty body)
            return response;
        } else {
            DWORD err = GetLastError();
            LOG_ERROR("GET request failed (attempt " + to_string(attempt) + "): " + to_string(err));
            WinHttpCloseHandle(hRequest);

            if (attempt >= maxRetries) break;

            int jitter = rand() % 200;
            Sleep(backoffMs + jitter);
            backoffMs *= 2;
            continue;
        }
    }

    // Exhausted retries
    return "";
}

string TranslationClient::ParseGoogleFreeResponse(const string& json) {
    string result;

    // Find the start of the sentence array: [[[
    size_t pos = json.find("[[[");
    if (pos == string::npos) return "";
    pos += 3; // now at opening " of first translated segment

    // Upper bound: the ]] that closes the outer sentence array
    size_t sentencesEnd = json.find("]]", pos);

    while (pos < json.size()) {
        if (json[pos] != '"') break;
        pos++; // skip opening "

        string segment;
        while (pos < json.size() && json[pos] != '"') {
            if (json[pos] == '\\' && pos + 1 < json.size()) {
                pos++;
                switch (json[pos]) {
                    case '"':  segment += '"';  break;
                    case '\\': segment += '\\'; break;
                    case 'n':  segment += '\n'; break;
                    case 'r':  segment += '\r'; break;
                    case 't':  segment += '\t'; break;
                    case 'u': {
                        if (pos + 4 < json.size()) {
                            string hex = json.substr(pos + 1, 4);
                            try {
                                unsigned int cp = stoul(hex, nullptr, 16);
                                segment += ConvertCodepointToUTF8(cp);
                                pos += 4;
                            } catch (...) {}
                        }
                        break;
                    }
                    default: segment += json[pos]; break;
                }
            } else {
                segment += json[pos];
            }
            pos++;
        }
        result += segment;
        if (pos < json.size()) pos++; // skip closing "

        // Find next inner array: ,["  within the sentence array bounds
        size_t nextInner = json.find(",[\"", pos);
        if (nextInner == string::npos ||
            (sentencesEnd != string::npos && nextInner > sentencesEnd)) break;
        pos = nextInner + 2; // point at the opening " of next segment
    }

    return result;
}

TranslationResult TranslationClient::TranslateText(const string& text, string& result,
                                                    const string& sourceLang,
                                                    const string& targetLang) {
    if (!initialized) return TranslationResult::INVALID_PARAMS;
    if (text.empty())  return TranslationResult::INVALID_PARAMS;

    // DLL-side cache check
    string cacheKey = GenerateCacheKey(text, sourceLang, targetLang);
    auto cacheIt = cache.find(cacheKey);
    if (cacheIt != cache.end() &&
        (GetTickCount() - cacheIt->second.timestamp) < CACHE_EXPIRY_MS) {
        result = cacheIt->second.translation;
        LOG_DEBUG("Cache hit: " + text.substr(0, 50));
        return TranslationResult::SUCCESS;
    }

    CleanExpiredCache();

    // Build Google Free GET path
    string sl = MapLangCode(sourceLang);
    string tl = MapLangCode(targetLang);
    string path = "/translate_a/single?client=gtx&sl=" + sl +
                  "&tl=" + tl + "&dt=t&q=" + UrlEncode(text);

    LOG_DEBUG("GET " + path.substr(0, 120));

    string response = HttpsGet(path);

    if (response == "HTTP_429") {
        return TranslationResult::RATE_LIMITED;
    }

    if (response.empty()) {
        LOG_ERROR("Empty response from Google Free");
        return TranslationResult::NETWORK_ERROR;
    }

    LOG_DEBUG("Response: " + response.substr(0, 200));

    string translation = ParseGoogleFreeResponse(response);

    if (translation.empty()) {
        LOG_ERROR("Failed to parse Google Free response");
        return TranslationResult::API_ERROR;
    }

    cache[cacheKey] = CacheEntry(translation);
    result = translation;
    LOG_DEBUG("Translated: " + text.substr(0, 30) + " -> " + translation.substr(0, 50));
    return TranslationResult::SUCCESS;
}

// Queue async translation request
bool TranslationClient::TranslateAsync(const string& requestId, the string& text,
                                       const string& sourceLang, const string& targetLang) {
    if (!initialized || !running) {
        return false;
    }

    lock_guard<mutex> lock(requestMutex);
    requestQueue.push(AsyncRequest(requestId, text, sourceLang, targetLang));
    LOG_DEBUG("Async request queued: " + requestId + " (" + sourceLang + " -> " + targetLang + ")");
    return true;
}

// Poll for completed translation
bool TranslationClient::PollResult(string& requestId, string& translation, string& error) {
    lock_guard<mutex> lock(resultMutex);

    if (resultQueue.empty()) {
        return false;
    }

    AsyncResult result = resultQueue.front();
    resultQueue.pop();

    requestId = result.requestId;
    translation = result.translation;
    error = result.error;

    return true;
}

// Get count of pending requests
size_t TranslationClient::GetPendingCount() {
    lock_guard<mutex> lock(requestMutex);
    return requestQueue.size();
}

// Worker thread for async translations
void TranslationClient::WorkerThreadFunc() {
    LOG_INFO("Worker thread started");

    while (running) {
        AsyncRequest request;
        bool hasRequest = false;

        {
            lock_guard<mutex> lock(requestMutex);
            if (!requestQueue.empty()) {
                request = requestQueue.front();
                requestQueue.pop();
                hasRequest = true;
            }
        }

        if (hasRequest) {
            LOG_DEBUG("Processing async request: " + request.requestId);

            string translation;
            string error;

            TranslationResult tr = TranslateText(request.text, translation,
                                                  request.sourceLang, request.targetLang);

            if (tr != TranslationResult::SUCCESS) {
                switch (tr) {
                    case TranslationResult::NETWORK_ERROR:  error = "network error"; break;
                    case TranslationResult::API_ERROR:      error = "API error";     break;
                    case TranslationResult::ENCODING_ERROR: error = "encoding error"; break;
                    case TranslationResult::TIMEOUT_ERROR:  error = "timeout";       break;
                    case TranslationResult::RATE_LIMITED:   error = "rate limited";  break;
                    default:                                error = "unknown error";  break;
                }
                translation = "";
            }

            {
                lock_guard<mutex> lock(resultMutex);
                resultQueue.push(AsyncResult(request.requestId, translation, error));
            }

            LOG_DEBUG("Async request completed: " + request.requestId);
        } else {
            Sleep(50);
        }
    }

    LOG_INFO("Worker thread stopped");
}
