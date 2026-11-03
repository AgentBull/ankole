package webdav

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/rclone/rclone/fs/config/configmap"
)

func TestAnkoleRefreshCancelsTheHTTPRequest(t *testing.T) {
	started := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("X-Ankole-Upload-Limit", "104857600")
			return
		}
		started <- struct{}{}
		<-r.Context().Done()
	}))
	t.Cleanup(server.Close)
	remote, err := NewFs(t.Context(), t.Name(), "", configmap.Simple{"url": server.URL, "vendor": "ankole"})
	if err != nil {
		t.Fatal(err)
	}
	object := remote.(*Fs).createObject("report.txt", time.Time{}, 0)
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	done := make(chan error, 1)
	go func() { done <- object.AnkoleRefresh(ctx) }()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("metadata request did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("metadata refresh did not preserve cancellation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("metadata request continued after cancellation")
	}
}

func TestAnkoleResponseRejectsInvalidMetadataWithoutChangingObject(t *testing.T) {
	for _, test := range []struct {
		name     string
		size     string
		modified string
	}{
		{name: "missing size", modified: "Mon, 02 Nov 2026 00:00:00 GMT"},
		{name: "invalid time", size: "42", modified: "invalid"},
	} {
		t.Run(test.name, func(t *testing.T) {
			response := &http.Response{Header: make(http.Header)}
			response.Header.Set("X-Ankole-Size", test.size)
			response.Header.Set("Last-Modified", test.modified)
			object := &Object{size: 123, ankoleETag: "original"}
			if err := object.ankoleResponse(response); err == nil {
				t.Fatal("invalid metadata was silently accepted")
			}
			if object.size != 123 || object.ankoleETag != "original" || object.hasMetaData {
				t.Fatal("invalid metadata changed the cached object")
			}
		})
	}
}

func TestAnkoleCopyPinsTheSourceVersion(t *testing.T) {
	const sourceETag = `"file:source:old"`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("X-Ankole-Upload-Limit", "104857600")
			return
		}
		if r.Method != "COPY" || r.Header.Get("X-Ankole-Expected-ETag") != sourceETag {
			t.Errorf("COPY lost its source version: %s, %q", r.Method, r.Header.Get("X-Ankole-Expected-ETag"))
		}
		if r.Header.Get("If-Match") != `"file:destination:old"` {
			t.Error("source condition replaced the destination condition")
		}
		w.Header().Set("X-Ankole-Size", "3")
		w.Header().Set("Last-Modified", "Tue, 03 Nov 2026 00:00:00 GMT")
		w.Header().Set("ETag", `"file:destination:new"`)
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(server.Close)
	remote, err := NewFs(t.Context(), t.Name(), "", configmap.Simple{"url": server.URL, "vendor": "ankole"})
	if err != nil {
		t.Fatal(err)
	}
	f := remote.(*Fs)
	source := f.createObject("source", time.Time{}, 3)
	source.ankoleETag = sourceETag
	if _, err := f.AnkoleCopy(t.Context(), source, "destination", "request", `"file:destination:old"`); err != nil {
		t.Fatal(err)
	}
}
