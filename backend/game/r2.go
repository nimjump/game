package game

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// r2.go — a minimal, dependency-free Cloudflare R2 client (R2 speaks the S3
// API, so this is really just a small hand-rolled AWS Signature Version 4
// signer + PUT/DELETE/List over net/http). Written by hand instead of
// pulling in aws-sdk-go-v2 or minio-go because this environment's shell has
// been persistently unable to run `go mod tidy`/`go get` this session (see
// earlier dependency-update work) — a stdlib-only client means nothing new
// needs to be fetched for this to build. It only implements the three
// operations the backup system actually needs: PutObject, ListObjectsV2,
// DeleteObject. Not a general-purpose S3 client.

const (
	r2Region  = "auto" // Cloudflare R2's fixed SigV4 region — always "auto", not a real AWS region
	r2Service = "s3"
	// sha256("") — the well-known payload hash for requests with no body
	// (GET/DELETE/list). Saved as a constant instead of computed every call.
	r2EmptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
)

type r2Config struct {
	accountID string
	accessKey string
	secretKey string
	bucket    string
	endpoint  string // https://<accountID>.r2.cloudflarestorage.com
}

// loadR2Config reads R2 credentials from the environment. Returns ok=false
// if any required piece is missing — callers should treat that as "backups
// are simply not configured yet" rather than an error, so a fresh deploy
// without R2 set up doesn't spam logs/alerts.
func loadR2Config() (r2Config, bool) {
	cfg := r2Config{
		accountID: strings.TrimSpace(os.Getenv("R2_ACCOUNT_ID")),
		accessKey: strings.TrimSpace(os.Getenv("R2_ACCESS_KEY_ID")),
		secretKey: strings.TrimSpace(os.Getenv("R2_SECRET_ACCESS_KEY")),
		bucket:    strings.TrimSpace(os.Getenv("R2_BUCKET")),
	}
	if cfg.accountID == "" || cfg.accessKey == "" || cfg.secretKey == "" || cfg.bucket == "" {
		return cfg, false
	}
	cfg.endpoint = strings.TrimSuffix(strings.TrimSpace(os.Getenv("R2_ENDPOINT")), "/")
	if cfg.endpoint == "" {
		cfg.endpoint = fmt.Sprintf("https://%s.r2.cloudflarestorage.com", cfg.accountID)
	}
	return cfg, true
}

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func hmacSHA256(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return mac.Sum(nil)
}

// awsURIEncode — RFC 3986 percent-encoding per AWS's SigV4 spec: unreserved
// characters (A-Z a-z 0-9 - _ . ~) pass through untouched, everything else
// is percent-encoded. When encodeSlash is false, '/' is also left alone
// (used for the canonical URI / path); when true, '/' is encoded as %2F
// (used for canonical query string values) — the one place path-encoding
// and query-encoding rules actually differ under SigV4.
func awsURIEncode(s string, encodeSlash bool) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		case c == '/' && !encodeSlash:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func canonicalQueryString(q url.Values) string {
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		for _, v := range q[k] {
			parts = append(parts, awsURIEncode(k, true)+"="+awsURIEncode(v, true))
		}
	}
	return strings.Join(parts, "&")
}

// r2Sign signs req in place (sets x-amz-date, x-amz-content-sha256 and
// Authorization headers) per AWS Signature Version 4. payloadHashHex must be
// the hex sha256 of the request body (or r2EmptyPayloadHash for bodyless
// requests, or the literal "UNSIGNED-PAYLOAD" for a streamed upload whose
// hash we don't want to compute up front).
func r2Sign(cfg r2Config, req *http.Request, payloadHashHex string) {
	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	req.Header.Set("x-amz-date", amzDate)
	req.Header.Set("x-amz-content-sha256", payloadHashHex)
	host := req.URL.Host

	headerNames := []string{"host", "x-amz-content-sha256", "x-amz-date"}
	headerValues := map[string]string{
		"host":                 host,
		"x-amz-content-sha256": payloadHashHex,
		"x-amz-date":           amzDate,
	}
	sort.Strings(headerNames)
	var canonicalHeaders strings.Builder
	for _, k := range headerNames {
		canonicalHeaders.WriteString(k)
		canonicalHeaders.WriteString(":")
		canonicalHeaders.WriteString(headerValues[k])
		canonicalHeaders.WriteString("\n")
	}
	signedHeaders := strings.Join(headerNames, ";")

	canonicalURI := awsURIEncode(req.URL.Path, false)
	if canonicalURI == "" {
		canonicalURI = "/"
	}

	canonicalRequest := strings.Join([]string{
		req.Method,
		canonicalURI,
		canonicalQueryString(req.URL.Query()),
		canonicalHeaders.String(),
		signedHeaders,
		payloadHashHex,
	}, "\n")

	credentialScope := fmt.Sprintf("%s/%s/%s/aws4_request", dateStamp, r2Region, r2Service)
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		credentialScope,
		sha256Hex([]byte(canonicalRequest)),
	}, "\n")

	kDate := hmacSHA256([]byte("AWS4"+cfg.secretKey), dateStamp)
	kRegion := hmacSHA256(kDate, r2Region)
	kService := hmacSHA256(kRegion, r2Service)
	kSigning := hmacSHA256(kService, "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(kSigning, stringToSign))

	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		cfg.accessKey, credentialScope, signedHeaders, signature,
	))
}

func r2ObjectURL(cfg r2Config, key string) string {
	return cfg.endpoint + "/" + cfg.bucket + "/" + key
}

// r2PutObject uploads body (size bytes, known up front — we always upload
// from a local temp file, never an unbounded stream) to the given object
// key. Uses UNSIGNED-PAYLOAD so we don't have to buffer/hash the whole file
// in memory first — R2 (like S3) accepts this for SigV4 PUT requests.
func r2PutObject(cfg r2Config, key string, body io.Reader, size int64, contentType string) error {
	req, err := http.NewRequest(http.MethodPut, r2ObjectURL(cfg, key), body)
	if err != nil {
		return err
	}
	req.ContentLength = size
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	r2Sign(cfg, req, "UNSIGNED-PAYLOAD")

	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("r2 put request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("r2 put failed: status=%d body=%s", resp.StatusCode, string(respBody))
	}
	return nil
}

// r2GetObject downloads an object. Caller MUST close the returned
// ReadCloser. Used only by the restore flow, always to stream straight into
// a local temp file — never call this and feed the result directly into
// something destructive (like DB.Load) without fully landing it on disk
// first, so a dropped connection mid-download can't leave things half-done.
func r2GetObject(cfg r2Config, key string) (io.ReadCloser, error) {
	req, err := http.NewRequest(http.MethodGet, r2ObjectURL(cfg, key), nil)
	if err != nil {
		return nil, err
	}
	r2Sign(cfg, req, r2EmptyPayloadHash)

	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("r2 get request failed: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		return nil, fmt.Errorf("r2 get failed: status=%d body=%s", resp.StatusCode, string(respBody))
	}
	return resp.Body, nil
}

func r2DeleteObject(cfg r2Config, key string) error {
	req, err := http.NewRequest(http.MethodDelete, r2ObjectURL(cfg, key), nil)
	if err != nil {
		return err
	}
	r2Sign(cfg, req, r2EmptyPayloadHash)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("r2 delete request failed: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 && resp.StatusCode != 404 {
		return fmt.Errorf("r2 delete failed: status=%d", resp.StatusCode)
	}
	return nil
}

type r2Object struct {
	Key          string
	Size         int64
	LastModified string
}

type r2ListResult struct {
	XMLName  xml.Name `xml:"ListBucketResult"`
	Contents []struct {
		Key          string `xml:"Key"`
		Size         int64  `xml:"Size"`
		LastModified string `xml:"LastModified"`
	} `xml:"Contents"`
	IsTruncated           bool   `xml:"IsTruncated"`
	NextContinuationToken string `xml:"NextContinuationToken"`
}

// r2ListObjects lists every object under prefix, transparently paging
// through ListObjectsV2's continuation tokens. Capped at 20 pages (20,000
// objects at the default max-keys=1000) as a sanity bound — this backup
// system will never come close to that many objects.
func r2ListObjects(cfg r2Config, prefix string) ([]r2Object, error) {
	var out []r2Object
	continuationToken := ""
	for page := 0; page < 20; page++ {
		q := url.Values{}
		q.Set("list-type", "2")
		q.Set("prefix", prefix)
		q.Set("max-keys", "1000")
		if continuationToken != "" {
			q.Set("continuation-token", continuationToken)
		}
		reqURL := cfg.endpoint + "/" + cfg.bucket + "?" + q.Encode()
		req, err := http.NewRequest(http.MethodGet, reqURL, nil)
		if err != nil {
			return nil, err
		}
		// Rebuild URL.RawQuery via url.Values so req.URL.Query() (used by the
		// signer) parses back out exactly what we set — url.Values.Encode()
		// and our own canonicalQueryString agree on sorted-key ordering.
		req.URL.RawQuery = q.Encode()
		r2Sign(cfg, req, r2EmptyPayloadHash)

		client := &http.Client{Timeout: 30 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("r2 list request failed: %w", err)
		}
		bodyBytes, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return nil, fmt.Errorf("r2 list failed: status=%d body=%s", resp.StatusCode, string(bodyBytes))
		}
		if readErr != nil {
			return nil, readErr
		}
		var parsed r2ListResult
		if err := xml.Unmarshal(bodyBytes, &parsed); err != nil {
			return nil, fmt.Errorf("r2 list: bad xml: %w", err)
		}
		for _, c := range parsed.Contents {
			out = append(out, r2Object{Key: c.Key, Size: c.Size, LastModified: c.LastModified})
		}
		if !parsed.IsTruncated || parsed.NextContinuationToken == "" {
			break
		}
		continuationToken = parsed.NextContinuationToken
	}
	return out, nil
}

// r2FormatBytes — human-readable size for logs/admin display.
func r2FormatBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return strconv.FormatInt(n, 10) + " B"
	}
	div, exp := int64(unit), 0
	for k := n / unit; k >= unit; k /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
