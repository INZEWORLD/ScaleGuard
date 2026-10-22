// ScaleGuard VPN core — thin mihomo (Clash.Meta) launcher.
//
// mihomo is used strictly as an out-of-process sidecar: this binary only boots
// the upstream core and exposes its RESTful controller on loopback. Keeping the
// core in its own process means the Flutter/Dart application never links mihomo
// code and therefore contains no GPL-3.0 derived work.
//
// Upstream: https://github.com/MetaCubeX/mihomo (GPL-3.0) — see MIHOMO_LICENSE
// in the application's android/ directory and NOTICE.txt next to this binary.
package main

import (
	"crypto/x509"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

// Overridden at link time with -X main.version=...
var version = "dev"

// coreVersion is the upstream mihomo build info reported by the core itself.
const coreVersion = "1.19.32"

// preferOwnChainBuilder takes TLS certificate verification off the Windows
// chain engine and leaves it to Go.
//
// Windows builds of Go verify a server certificate by handing the chain to
// crypt32 (`CertGetCertificateChain`/`CertVerifyCertificateChainPolicy`) and
// releasing it with `CertFreeCertificateChain`. That release crashes with an
// access violation (0xc0000005) on a small number of machines — damaged entries
// in the local root store and security products that hook crypt32 are the usual
// causes — and a VPN core that dies mid-session takes the user's whole
// connection with it, so the crash is not something the client can simply
// ignore.
//
// Handing Go the very same roots and asking it to build the chain itself keeps
// verification exactly as strict (same trust anchors, same expiry and hostname
// rules) while never entering the crashing code path. The environment knob is
// what makes the fallback pool actually win over the platform verifier; on its
// own `SetFallbackRoots` is ignored on Windows.
func preferOwnChainBuilder() {
	if value, present := os.LookupEnv("GODEBUG"); present {
		for _, part := range strings.Split(value, ",") {
			if strings.HasPrefix(part, "x509usefallbackroots=") {
				// An explicit setting always wins.
				return
			}
		}
	}
	_ = os.Setenv("GODEBUG", strings.Join(
		[]string{os.Getenv("GODEBUG"), "x509usefallbackroots=1"}, ","))

	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		fmt.Fprintf(os.Stderr,
			"scaleguard-core: system roots unavailable (%v), using Go's own pool\n", err)
		return
	}
	x509.SetFallbackRoots(pool)
}

func main() {
	preferOwnChainBuilder()

	var (
		configPath = flag.String("config", "", "absolute path to the mihomo config.yaml")
		dataDir    = flag.String("d", "", "working directory for cache and geo databases")
		secret     = flag.String("secret", "", "bearer secret for the RESTful controller")
		controller = flag.String("controller", "127.0.0.1:9090", "RESTful controller bind address")
		logLevel   = flag.String("log-level", "warning", "log level: silent|error|warning|info|debug")
		showVer    = flag.Bool("version", false, "print core version and exit")
	)
	flag.Parse()

	if *showVer {
		fmt.Printf("scaleguard-core %s (mihomo %s)\n", version, coreVersion)
		return
	}
	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "scaleguard-core: -config is required")
		os.Exit(2)
	}

	// mihomo resolves its cache file and any geo databases relative to the
	// working directory, so the parent process points it at a writable app-data
	// folder instead of letting it fall back to a non-existent home path.
	if *dataDir != "" {
		if err := os.MkdirAll(*dataDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "scaleguard-core: cannot create data dir: %v\n", err)
			os.Exit(2)
		}
		if err := os.Chdir(*dataDir); err != nil {
			fmt.Fprintf(os.Stderr, "scaleguard-core: cannot enter data dir: %v\n", err)
			os.Exit(2)
		}
	}

	configBytes, err := os.ReadFile(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaleguard-core: cannot read config: %v\n", err)
		os.Exit(2)
	}
	if len(configBytes) == 0 {
		fmt.Fprintln(os.Stderr, "scaleguard-core: config is empty")
		os.Exit(2)
	}

	if level, ok := log.LogLevelMapping[strings.ToLower(*logLevel)]; ok {
		log.SetLevel(level)
	}

	// hub.Parse boots the whole core: inbounds, DNS, tun (when configured) and
	// the RESTful controller the Flutter UI drives. Passing the controller and
	// secret as options keeps them out of the (user-influenced) config file.
	if err := hub.Parse(
		configBytes,
		hub.WithExternalController(*controller),
		hub.WithSecret(*secret),
	); err != nil {
		fmt.Fprintf(os.Stderr, "scaleguard-core: core failed to start: %v\n", err)
		os.Exit(1)
	}

	// Readiness marker: the Dart side waits for this line before issuing API
	// calls, which removes any startup race with the controller socket.
	fmt.Printf("scaleguard-core %s ready controller=%s\n", version, *controller)
	os.Stdout.Sync()

	// Terminate cleanly so TUN adapters, DNS listeners and the controller
	// socket are released instead of leaking on the next launch.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	<-signals
	executor.Shutdown()
}
