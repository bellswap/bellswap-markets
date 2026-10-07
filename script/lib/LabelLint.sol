// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LabelLint
/// @notice Off-chain naming rules for the label menu of BellMarketFactoryV2 (src/mint/BellMarketFactoryV2.sol). The
/// factory constructor enforces only the charset and length rules (and uniqueness); which words a label may carry is
/// policy, checked here before deployment (script/DeployMintV2.s.sol), before listing (script/CreateMarketV2.s.sol),
/// and on the decoded menu of a deployed factory (script/Check.s.sol), so a config override cannot slip past it.
/// Rules, on the name and the symbol, case-insensitive:
/// - the on-chain rules, mirrored: name 3 to 40 printable ASCII bytes, no leading or trailing space; symbol 2 to 11
///   bytes of A-Z and 0-9, not starting with a digit;
/// - no banned word: "stock" and "share" (the synthetic holds no shares, SPEC 14.1), "ondo", "hood" and "robinhood"
///   (third-party brands, SPEC 14.1, test/spec/NamingLint.t.sol), the reference fund's name ("breakwave", "tanker
///   shipping") and its ticker ("bwet"), and "etf" (docs/COUNSEL.md:99: tickers and fund names stay off chain metadata).
///   A banned word matches as a whole word (hasWord): letters and digits are word characters, so "etf" in "Netflix" and
///   "ondo" in "London" pass while "Ondo Tanker" and "ETF Tracker" fail; a plural "s" still matches ("Shares"). A
///   symbol is one run of word characters with nothing to split on, so there a banned word also matches as a prefix or
///   a suffix ("SBWET", "ETFX", "BSHOOD"), the affixed-ticker forms ("sBWET style", docs/COUNSEL.md:99);
/// - the symbol is not the collateral's ("USDG" anywhere in it) and not in the v1 generated namespace (prefix "BSX"),
///   and the name does not start with the v1 generated "Bellswap Synthetic #".
/// Changing a rule is a policy change: it needs the counsel clearance of docs/COUNSEL.md, not only a code review.
library LabelLint {
    uint256 internal constant MIN_NAME = 3;
    uint256 internal constant MAX_NAME = 40;
    uint256 internal constant MIN_SYMBOL = 2;
    uint256 internal constant MAX_SYMBOL = 11;

    /// @notice The banned words, lower case, matched by hasWord on the lower-cased name (whole words) and symbol
    /// (whole symbol, prefix or suffix).
    function bannedWords() internal pure returns (string[9] memory) {
        return ["stock", "share", "ondo", "hood", "robinhood", "breakwave", "tanker shipping", "bwet", "etf"];
    }

    /// @notice (true, "") when the label passes every rule, else (false, the first rule it breaks).
    function check(string memory name, string memory symbol) internal pure returns (bool ok, string memory why) {
        bytes memory n = bytes(name);
        bytes memory s = bytes(symbol);
        if (!nameCharset(n)) return (false, "name: 3 to 40 printable ASCII bytes, no leading or trailing space");
        if (!symbolCharset(s)) return (false, "symbol: 2 to 11 bytes of A-Z and 0-9, not starting with a digit");
        string memory ln = string(lower(n));
        string memory ls = string(lower(s));
        string[9] memory words = bannedWords();
        for (uint256 i; i < words.length; ++i) {
            if (hasWord(ln, words[i], false)) return (false, string.concat("name contains a banned word: ", words[i]));
            if (hasWord(ls, words[i], true)) {
                return (false, string.concat("symbol contains a banned word: ", words[i]));
            }
        }
        if (contains(ls, "usdg")) return (false, "symbol contains USDG, the collateral's symbol");
        if (startsWith(s, "BSX")) return (false, "symbol in the v1 generated namespace bsX<id>");
        if (startsWith(lower(n), "bellswap synthetic #")) {
            return (false, "name in the v1 generated namespace Bellswap Synthetic #<id>");
        }
        return (true, "");
    }

    /// @notice The factory's on-chain name rule (BellMarketFactoryV2._isName).
    function nameCharset(bytes memory b) internal pure returns (bool) {
        uint256 len = b.length;
        if (len < MIN_NAME || len > MAX_NAME) return false;
        if (b[0] == 0x20 || b[len - 1] == 0x20) return false;
        for (uint256 k; k < len; ++k) {
            if (b[k] < 0x20 || b[k] > 0x7e) return false;
        }
        return true;
    }

    /// @notice The factory's on-chain symbol rule (BellMarketFactoryV2._isSymbol).
    function symbolCharset(bytes memory b) internal pure returns (bool) {
        uint256 len = b.length;
        if (len < MIN_SYMBOL || len > MAX_SYMBOL) return false;
        for (uint256 k; k < len; ++k) {
            bytes1 c = b[k];
            bool letter = c >= 0x41 && c <= 0x5a;
            bool digit = c >= 0x30 && c <= 0x39;
            if (!letter && !(digit && k != 0)) return false;
        }
        return true;
    }

    function lower(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length);
        for (uint256 k; k < b.length; ++k) {
            bytes1 c = b[k];
            out[k] = c >= 0x41 && c <= 0x5a ? bytes1(uint8(c) + 32) : c;
        }
    }

    /// @notice Whether `word` occurs in `hay` as a whole word: the byte before the match and the byte after it are not
    /// word characters (A-Z, a-z, 0-9), or are past the ends of `hay`. One "s" after the word is allowed (a plural:
    /// "shares", "etfs"). `word` may hold spaces ("tanker shipping"); `hay` and `word` are compared byte for byte, so
    /// callers pass both lower-cased. With `affix`, a match at the start or at the end of `hay` counts whatever follows
    /// or precedes it (symbols: "sbwet", "etfx").
    function hasWord(string memory hay, string memory word, bool affix) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory w = bytes(word);
        uint256 n = w.length;
        uint256 len = h.length;
        if (n == 0 || n > len) return false;
        for (uint256 i; i + n <= len; ++i) {
            if (!_matchAt(h, w, i)) continue;
            uint256 e = i + n;
            bool startOk = i == 0 || !isWordChar(h[i - 1]);
            bool endOk = e == len || !isWordChar(h[e]) || (h[e] == "s" && (e + 1 == len || !isWordChar(h[e + 1])));
            if (startOk && endOk) return true;
            if (affix && (i == 0 || endOk)) return true;
        }
        return false;
    }

    /// @notice Letters and digits are word characters; everything else (space, punctuation) separates words.
    function isWordChar(bytes1 c) internal pure returns (bool) {
        return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    }

    /// @notice keccak256 of the ASCII-lower-cased bytes: the key under which two names (or symbols) count as the same
    /// label text, as in BellMarketFactoryV2._checkLabel.
    function foldedHash(string memory s) internal pure returns (bytes32) {
        return keccak256(lower(bytes(s)));
    }

    function _matchAt(bytes memory h, bytes memory w, uint256 i) private pure returns (bool) {
        for (uint256 j; j < w.length; ++j) {
            if (h[i + j] != w[j]) return false;
        }
        return true;
    }

    function contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function startsWith(bytes memory b, bytes memory prefix) internal pure returns (bool) {
        if (b.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (b[i] != prefix[i]) return false;
        }
        return true;
    }
}
