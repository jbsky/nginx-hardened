// Nginx WAF hardened init — replaces curl healthcheck + shell entrypoint.
// Static binary, zero shell dependency.
//
// Usage:
//
//	init --healthcheck      run Docker healthcheck (exit 0/1)
//	init --setup-dirs       create runtime directories (build-time, FROM scratch)
//	init [CMD [ARGS...]]    entrypoint: config test, then exec CMD
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

const (
	nginxUID     = 1999
	nginxGID     = 1999
	healthURL    = "http://127.0.0.1:80/healthz"
	defaultConf  = "/etc/nginx/nginx.conf"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--healthcheck":
			os.Exit(healthcheck())
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}
	if err := entrypoint(); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories — called at build time in FROM scratch stage.
// ---------------------------------------------------------------------------

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		{"/var", 0755, 0, 0},
		{"/var/log", 0755, 0, 0},
		{"/var/cache", 0755, 0, 0},
		{"/var/run", 0755, 0, 0},
		{"/var/lib", 0755, 0, 0},
		{"/var/www", 0755, 0, 0},
		{"/var/www/html", 0755, nginxUID, nginxGID},
		{"/var/log/nginx", 0755, nginxUID, nginxGID},
		{"/var/cache/nginx", 0755, nginxUID, nginxGID},
		{"/var/cache/nginx/client_temp", 0755, nginxUID, nginxGID},
		{"/var/cache/nginx/proxy_temp", 0755, nginxUID, nginxGID},
		{"/var/cache/nginx/fastcgi_temp", 0755, nginxUID, nginxGID},
		{"/var/cache/nginx/uwsgi_temp", 0755, nginxUID, nginxGID},
		{"/var/cache/nginx/scgi_temp", 0755, nginxUID, nginxGID},
		{"/var/run/nginx", 0755, nginxUID, nginxGID},
		{"/var/lib/modsecurity", 0755, nginxUID, nginxGID},
		{"/var/lib/modsecurity/tmp", 0755, nginxUID, nginxGID},
		{"/var/lib/modsecurity/data", 0755, nginxUID, nginxGID},
		{"/tmp", 01777, 0, 0},
	}
	for _, d := range dirs {
		fmt.Printf("[init] mkdir %s (mode=%04o uid=%d gid=%d)\n", d.path, d.mode, d.uid, d.gid)
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}

	// Create symlinks for log output
	for _, link := range []struct{ src, dst string }{
		{"/dev/stdout", "/var/log/nginx/access.log"},
		{"/dev/stderr", "/var/log/nginx/error.log"},
	} {
		os.Remove(link.dst) // ignore error
		if err := os.Symlink(link.src, link.dst); err != nil {
			return fmt.Errorf("symlink %s -> %s: %w", link.dst, link.src, err)
		}
	}

	// Create PID file placeholder
	pidFile := "/var/run/nginx/nginx.pid"
	f, err := os.Create(pidFile)
	if err != nil {
		return fmt.Errorf("create %s: %w", pidFile, err)
	}
	f.Close()
	os.Chown(pidFile, nginxUID, nginxGID)

	fmt.Println("[init] setup-dirs complete")
	return nil
}

// ---------------------------------------------------------------------------
// Healthcheck: HTTP GET /healthz
// ---------------------------------------------------------------------------

func healthcheck() int {
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
		},
	}
	resp, err := client.Get(healthURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s failed: %v\n", healthURL, err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s returned %d\n", healthURL, resp.StatusCode)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// Entrypoint: validate config then exec nginx
// ---------------------------------------------------------------------------

func entrypoint() error {
	conf := envGet("NGINX_CONF", defaultConf)

	if !exists(conf) {
		return fmt.Errorf("config file %s not found", conf)
	}

	// Ensure writable dirs
	for _, dir := range []string{"/var/log/nginx", "/var/cache/nginx", "/var/run/nginx", "/var/lib/modsecurity"} {
		if err := ensureWritable(dir, nginxUID, nginxGID); err != nil {
			log("WARNING: %v", err)
		}
	}

	// Config validation (nginx -t)
	log("Validating configuration...")
	if err := run("/usr/sbin/nginx", "-t", "-c", conf); err != nil {
		return fmt.Errorf("nginx config test failed: %w", err)
	}
	log("Configuration OK")

	// Exec nginx (replaces this process)
	log("Starting Nginx")
	return execCmd(os.Args[1:])
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func envGet(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func execCmd(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("no command specified")
	}
	bin, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("command not found: %s", args[0])
	}
	return syscall.Exec(bin, args, os.Environ())
}

func ensureWritable(path string, uid, gid int) error {
	if !exists(path) {
		return nil
	}
	tmp, err := os.CreateTemp(path, ".write-test-*")
	if err == nil {
		name := tmp.Name()
		tmp.Close()
		os.Remove(name)
		return nil
	}
	if chErr := chownRecursive(path, uid, gid); chErr == nil {
		tmp2, err2 := os.CreateTemp(path, ".write-test-*")
		if err2 == nil {
			name := tmp2.Name()
			tmp2.Close()
			os.Remove(name)
			return nil
		}
	}
	return fmt.Errorf("%s is not writable by uid %d", path, os.Getuid())
}

func chownRecursive(path string, uid, gid int) error {
	return filepath.Walk(path, func(name string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chown(name, uid, gid)
	})
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}
