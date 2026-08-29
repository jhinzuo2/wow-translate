// curl_bridge.cpp - a single HTTPS GET via libcurl (OpenSSL backend), kept in its
// own translation unit for the same reason wininet_bridge.cpp was: curl/curl.h and
// windows.h/wininet.h/winhttp.h have historically had macro/typedef collisions
// (notably around CURL's use of `IN`/`OUT` and windows.h's), so this stays isolated.

#include <curl/curl.h>
#include <mutex>
#include <cstring>

#include "../include/curl_bridge.h"
#include "../include/logging.h"

using namespace std;

namespace {

string PreviewBody(const string& body, size_t maxLen = 400) {
    string preview = body.substr(0, min(body.length(), maxLen));
    size_t pos = 0;
    while ((pos = preview.find("\r\n", pos)) != string::npos) {
        preview.replace(pos, 2, " | ");
        pos += 3;
    }
    if (body.length() > maxLen) {
        preview += "... (" + to_string(body.length()) + " bytes total)";
    }
    return preview;
}

size_t WriteBodyCallback(char* ptr, size_t size, size_t nmemb, void* userdata) {
    size_t bytes = size * nmemb;
    static_cast<string*>(userdata)->append(ptr, bytes);
    return bytes;
}

size_t WriteHeaderCallback(char* ptr, size_t size, size_t nmemb, void* userdata) {
    size_t bytes = size * nmemb;
    static_cast<string*>(userdata)->append(ptr, bytes);
    return bytes;
}

// Only kept for LOG_DEBUG's -v-equivalent output when something goes wrong;
// swallowed entirely on success to avoid spamming the log per-request.
struct DebugCapture {
    string lines;
};

int DebugCallback(CURL*, curl_infotype type, char* data, size_t size, void* userptr) {
    if (type != CURLINFO_TEXT && type != CURLINFO_HEADER_OUT && type != CURLINFO_HEADER_IN) {
        return 0;
    }
    auto* capture = static_cast<DebugCapture*>(userptr);
    capture->lines.append(data, size);
    return 0;
}

once_flag g_globalInitFlag;
bool g_globalInitOk = false;

} // namespace

namespace {

// Deliberately NOT called from DllMain: curl_global_init() can internally call
// LoadLibrary (e.g. resolving ws2_32.dll/crypto providers), and LoadLibrary from
// inside DllMain risks a loader-lock deadlock - especially relevant here since
// this DLL is injected into another process's (WoW's) address space rather than
// being its own EXE. Instead this runs lazily on the worker thread's first
// request, well after DLL_PROCESS_ATTACH has returned and the loader lock is free.
void DoGlobalInitOnce() {
    CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (rc != CURLE_OK) {
        LOG_ERROR(string("curl: curl_global_init failed: ") + curl_easy_strerror(rc));
        g_globalInitOk = false;
        return;
    }

    // Sanity-check the SSL backend actually linked in is what we expect (OpenSSL,
    // not Schannel) - if this ever logs "Schannel" it means the prebuilt curl lib
    // in use was built against the OS TLS stack and this bridge isn't buying us
    // anything over WinINet/WinHTTP. Check this log line after first deployment.
    curl_version_info_data* info = curl_version_info(CURLVERSION_NOW);
    if (info && info->ssl_version) {
        LOG_INFO(string("curl SSL backend: ") + info->ssl_version);
    } else {
        LOG_WARNING("curl: could not determine linked SSL backend");
    }

    g_globalInitOk = true;
}

} // namespace

bool CurlBridgeGlobalInit(string& outError) {
    call_once(g_globalInitFlag, DoGlobalInitOnce);
    if (!g_globalInitOk) {
        outError = "curl_global_init failed - see log for curl_easy_strerror detail";
    }
    return g_globalInitOk;
}

void CurlBridgeGlobalCleanup() {
    if (g_globalInitOk) {
        curl_global_cleanup();
        g_globalInitOk = false;
    }
}

string CurlHttpsGet(const string& host, int port, const string& pathAndQuery,
                     const vector<pair<string, string>>& headers,
                     long& statusCode, string& outError) {
    statusCode = 0;
    outError.clear();

    string initError;
    if (!CurlBridgeGlobalInit(initError)) {
        outError = initError;
        return "";
    }

    CURL* curl = curl_easy_init();
    if (!curl) {
        outError = "curl_easy_init failed";
        LOG_ERROR("curl: " + outError);
        return "";
    }

    string url = "https://" + host + ":" + to_string(port) + pathAndQuery;

    string responseBody;
    string responseHeaders;
    DebugCapture debugCapture;

    curl_slist* headerList = nullptr;
    for (const auto& header : headers) {
        if (!header.first.empty() && !header.second.empty()) {
            string line = header.first + ": " + header.second;
            headerList = curl_slist_append(headerList, line.c_str());
        }
    }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    if (headerList) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerList);
    }

    // Same User-Agent that worked from native x64 PowerShell (Invoke-WebRequest).
    curl_easy_setopt(curl, CURLOPT_USERAGENT,
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36");

    // Force TLS 1.2 minimum and let curl/OpenSSL pick its own default cipher
    // list/order - this is the whole point, we do NOT want to inherit anything
    // from Schannel/WOW64 here.
    curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteBodyCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, WriteHeaderCallback);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &responseHeaders);

    // 8-second timeouts, matching the WinINet/WinHTTP paths' fail-fast behavior.
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 8000L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 8000L);

    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);          // required for thread safety
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);    // match prior behavior, no redirects
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);

    curl_easy_setopt(curl, CURLOPT_DEBUGFUNCTION, DebugCallback);
    curl_easy_setopt(curl, CURLOPT_DEBUGDATA, &debugCapture);
    curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);

    LOG_DEBUG("curl GET " + url);
    if (headerList) {
        string headerBlock;
        for (const auto& header : headers) {
            if (!header.first.empty() && !header.second.empty()) {
                headerBlock += header.first + ": " + header.second + "\r\n";
            }
        }
        LOG_DEBUG("curl request headers: " + headerBlock);
    }

    CURLcode rc = curl_easy_perform(curl);

    if (rc == CURLE_OK) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &statusCode);

        if (statusCode != 200) {
            LOG_WARNING("curl response status: " + to_string(statusCode));
            LOG_WARNING("curl response headers: " + responseHeaders);
            LOG_WARNING("curl response body: " + PreviewBody(responseBody));
            // Only dump the handshake/header trace when something went wrong -
            // this is what tells you whether the fingerprint theory holds:
            // compare this against a passing request's trace if you capture one.
            LOG_DEBUG("curl trace: " + debugCapture.lines);
        } else {
            LOG_DEBUG("curl response status: 200, " + to_string(responseBody.length()) + " bytes");
        }
    } else {
        outError = string("curl_easy_perform failed: ") + curl_easy_strerror(rc);
        LOG_ERROR("curl: " + outError);
        LOG_DEBUG("curl trace: " + debugCapture.lines);
    }

    if (headerList) {
        curl_slist_free_all(headerList);
    }
    curl_easy_cleanup(curl);

    return responseBody;
}
