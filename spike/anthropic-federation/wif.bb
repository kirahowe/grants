#!/usr/bin/env bb
;; Throwaway ES256 JWT tooling for the Anthropic WIF spike.
;; Crypto is done by openssl (key generation, signing, verification);
;; this script only does the JSON / base64url / DER<->raw plumbing.
;;
;;   bb wif.bb jwks   KEY.pem KID               -> prints JWKS JSON
;;   bb wif.bb keys   KEY.pem KID               -> prints just the keys array (what the API's jwks.keys wants)
;;   bb wif.bb jwt    KEY.pem KID ISS SUB [AUD] [TTL-SECONDS] [EXTRA-JSON]  -> prints a signed JWT
;;   bb wif.bb verify KEY.pem JWT               -> verifies with openssl, exit 0/1
;;   bb wif.bb decode JWT                       -> prints header and claims
(require '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])
(import '(java.util Base64) '(java.io ByteArrayOutputStream))

(defn b64u [^bytes bs] (.encodeToString (.withoutPadding (Base64/getUrlEncoder)) bs))
(defn unb64u [^String s] (.decode (Base64/getUrlDecoder) s))
(defn sh-bytes [args stdin-bytes]
  ;; run a command with raw bytes on stdin, return raw bytes on stdout
  (let [pb (ProcessBuilder. ^java.util.List args)
        _ (.redirectError pb java.lang.ProcessBuilder$Redirect/INHERIT)
        proc (.start pb)]
    (with-open [o (.getOutputStream proc)] (.write o ^bytes stdin-bytes))
    (let [out (.readAllBytes (.getInputStream proc))
          rc (.waitFor proc)]
      (when-not (zero? rc) (throw (ex-info (str "command failed: " (pr-str args)) {:rc rc})))
      out)))

(defn pub-point [key-pem]
  ;; SPKI DER for P-256 is 91 bytes; the last 65 are 0x04 || X || Y
  (let [der (sh-bytes ["openssl" "pkey" "-in" key-pem "-pubout" "-outform" "DER"] (byte-array 0))
        pt  (java.util.Arrays/copyOfRange der (- (alength der) 65) (alength der))]
    (assert (= 91 (alength der)) "not a P-256 SPKI")
    (assert (= 4 (aget pt 0)) "not an uncompressed point")
    {:x (b64u (java.util.Arrays/copyOfRange pt 1 33))
     :y (b64u (java.util.Arrays/copyOfRange pt 33 65))}))

(defn jwk [key-pem kid]
  (merge {:kty "EC" :crv "P-256" :use "sig" :alg "ES256" :kid kid} (pub-point key-pem)))

;; DER ECDSA-Sig-Value <-> raw r||s (RFC 7515 section 3.4)
(defn der->raw [^bytes der]
  (let [rd (fn [off] ;; read INTEGER at off -> [bytes next-off]
             (assert (= 2 (aget der off)))
             (let [len (bit-and 0xff (aget der (+ off 1)))
                   v   (java.util.Arrays/copyOfRange der (+ off 2) (+ off 2 len))
                   v   (loop [v v] (if (and (> (alength v) 32) (zero? (aget v 0))) (recur (java.util.Arrays/copyOfRange v 1 (alength v))) v))
                   pad (byte-array 32)]
               (System/arraycopy v 0 pad (- 32 (alength v)) (alength v))
               [pad (+ off 2 len)]))
        ;; header: 0x30 len [0x81 len]
        start (if (= (bit-and 0xff (aget der 1)) 0x81) 3 2)
        [r nxt] (rd start)
        [s _]   (rd nxt)
        out (byte-array 64)]
    (System/arraycopy r 0 out 0 32) (System/arraycopy s 0 out 32 32) out))

(defn raw->der [^bytes raw]
  (let [int-bytes (fn [off] (let [v (java.util.Arrays/copyOfRange raw off (+ off 32))
                                  v (loop [v v] (if (and (> (alength v) 1) (zero? (aget v 0))) (recur (java.util.Arrays/copyOfRange v 1 (alength v))) v))
                                  v (if (neg? (aget v 0)) (byte-array (cons 0 v)) v)]
                              v))
        r (int-bytes 0) s (int-bytes 32)
        body (ByteArrayOutputStream.)]
    (.write body 2) (.write body (alength r)) (.write body ^bytes r)
    (.write body 2) (.write body (alength s)) (.write body ^bytes s)
    (let [b (.toByteArray body) out (ByteArrayOutputStream.)]
      (.write out 0x30) (.write out (alength b)) (.write out ^bytes b) (.toByteArray out))))

(defn sign-input [key-pem ^String signing-input]
  (der->raw (sh-bytes ["openssl" "dgst" "-sha256" "-sign" key-pem] (.getBytes signing-input "UTF-8"))))

(defn rand-hex [n] (apply str (repeatedly n #(format "%x" (rand-int 16)))))

(defn make-jwt [key-pem kid iss sub aud ttl extra]
  (let [now (quot (System/currentTimeMillis) 1000)
        hdr {:alg "ES256" :typ "JWT" :kid kid}
        clm (merge {:iss iss :sub sub :aud aud :iat now :nbf now :exp (+ now ttl)
                    :jti (str (java.util.UUID/randomUUID))}
                   extra)
        si  (str (b64u (.getBytes (json/generate-string hdr) "UTF-8")) "."
                 (b64u (.getBytes (json/generate-string clm) "UTF-8")))]
    (str si "." (b64u (sign-input key-pem si)))))

(defn verify-jwt [key-pem jwt]
  (let [[h c s] (str/split jwt #"\.")
        si (str h "." c)
        der (raw->der (unb64u s))
        tmp (java.io.File/createTempFile "sig" ".der")]
    (try
      (with-open [o (java.io.FileOutputStream. tmp)] (.write o ^bytes der))
      (let [pubf (java.io.File/createTempFile "pub" ".pem")]
        (spit pubf (:out (p/shell {:out :string} "openssl" "pkey" "-in" key-pem "-pubout")))
        (let [r (p/process {:in (.getBytes si "UTF-8") :out :string :err :string}
                           "openssl" "dgst" "-sha256" "-verify" (str pubf) "-signature" (str tmp))
              res @r]
          (.delete pubf)
          (zero? (:exit res))))
      (finally (.delete tmp)))))

(defn decode [jwt]
  (let [[h c _] (str/split jwt #"\.")]
    {:header (json/parse-string (String. (unb64u h) "UTF-8") true)
     :claims (json/parse-string (String. (unb64u c) "UTF-8") true)}))

(let [[cmd & args] *command-line-args*]
  (case cmd
    "jwks"   (let [[k kid] args] (println (json/generate-string {:keys [(jwk k kid)]} {:pretty true})))
    "keys"   (let [[k kid] args] (println (json/generate-string [(jwk k kid)])))
    "jwt"    (let [[k kid iss sub aud ttl extra] args]
               (println (make-jwt k kid iss sub (or aud "https://api.anthropic.com")
                                  (Long/parseLong (or ttl "300"))
                                  (when extra (json/parse-string extra true)))))
    "verify" (let [[k jwt] args] (if (verify-jwt k jwt) (println "signature OK") (do (println "signature BAD") (System/exit 1))))
    "decode" (println (json/generate-string (decode (first args)) {:pretty true}))
    (do (binding [*out* *err*] (println "usage: wif.bb jwks|keys|jwt|verify|decode ..."))
        (System/exit 2))))
