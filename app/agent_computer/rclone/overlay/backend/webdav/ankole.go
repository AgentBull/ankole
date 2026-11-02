package webdav

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/rclone/rclone/backend/webdav/api"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/internal/ankole"
	"github.com/rclone/rclone/lib/rest"
)

func (f *Fs) AnkoleState() *ankole.State { return f.ankole }
func (f *Fs) SetToken(token string)      { f.srv.SetHeader("Authorization", "Bearer "+token) }
func (f *Fs) ankoleUploadLimit(ctx context.Context) error {
	response, err := f.srv.Call(ctx, &rest.Opts{Method: "OPTIONS", Path: "", NoResponse: true})
	if err != nil {
		return err
	}
	limit, err := strconv.ParseInt(response.Header.Get("X-Ankole-Upload-Limit"), 10, 64)
	if err != nil {
		return err
	}
	f.ankole.SetUploadLimit(limit)
	return nil
}

func (o *Object) ankoleResponse(response *http.Response) error {
	size, err := strconv.ParseInt(response.Header.Get("X-Ankole-Size"), 10, 64)
	if err != nil {
		return fmt.Errorf("read upload size: %w", err)
	}
	modified, err := http.ParseTime(response.Header.Get("Last-Modified"))
	if err != nil {
		return fmt.Errorf("read upload modification time: %w", err)
	}
	o.ankoleETag = response.Header.Get("ETag")
	o.ankoleDigest = response.Header.Get("X-Ankole-Fingerprint")
	o.ankoleNodeID = response.Header.Get("X-Ankole-Node-Id")
	o.ankoleRefreshBody = response.Header.Get("X-Ankole-Refresh-Body") == "1"
	o.size = size
	o.modTime = modified
	o.hasMetaData = true
	return nil
}

func ankoleError(response *http.Response, err error) error {
	if err == nil {
		return nil
	}
	code := 0
	if response != nil {
		code = response.StatusCode
	}
	if dav, ok := errors.AsType[*api.Error](err); ok {
		code = dav.StatusCode
	}
	switch code {
	case 400, 403, 404, 409, 412, 413, 422:
		return &ankole.TerminalError{Status: code, Message: err.Error()}
	}
	return err
}

func (o *Object) AnkoleFingerprint() string { return o.ankoleDigest }
func (o *Object) AnkoleETag() string        { return o.ankoleETag }
func (o *Object) AnkoleRefreshBody() bool   { return o.ankoleRefreshBody }
func (o *Object) AnkoleNodeID() string      { return o.ankoleNodeID }
func (o *Object) AnkoleReadOpened() {
	if o.fs.ankole != nil {
		o.fs.ankole.ReadOpened(o.remote, o.ankoleETag)
	}
}
func (o *Object) ID() string { return o.ankoleNodeID }
func (o *Object) AnkoleAtPath(name string) fs.Object {
	moved := *o
	moved.remote = name
	return &moved
}
func (o *Object) AnkoleRefresh(ctx context.Context) error {
	o.hasMetaData = false
	return o.readMetaData(ctx)
}

// MOVE must reach the server with its target intact. Generic operations.Move
// deletes a destination first on backends which cannot be identified as local.
func (f *Fs) AnkoleMove(ctx context.Context, src fs.Object, name string) (fs.Object, error) {
	if f.ankole == nil {
		return f.Move(ctx, src, name)
	}
	return f.ankoleMove(ctx, src.Remote(), name)
}

func (f *Fs) ankoleMove(ctx context.Context, source, name string) (fs.Object, error) {
	headers := map[string]string{"Destination": f.endpointURL + f.filePath(name), "Overwrite": "T"}
	if baseline := f.ankole.ReadETag(name); baseline != "" {
		headers["If-Match"] = baseline
	}
	headers["X-Ankole-Request-Id"] = uuid.NewString()
	var response *http.Response
	var err error
	err = f.pacer.Call(func() (bool, error) {
		response, err = f.srv.Call(ctx, &rest.Opts{Method: "MOVE", Path: f.filePath(source), ExtraHeaders: headers, NoResponse: true})
		return f.shouldRetry(ctx, response, err)
	})
	if err != nil {
		return nil, ankoleError(response, err)
	}
	object := f.createObject(name, time.Time{}, 0)
	if err := object.ankoleResponse(response); err != nil {
		return nil, err
	}
	return object, nil
}

func (f *Fs) AnkoleCopy(ctx context.Context, src fs.Object, name, requestID, baseline string) (fs.Object, error) {
	source, ok := src.(*Object)
	if f.ankole == nil || !ok || !strings.HasPrefix(source.ankoleETag, "\"file:") {
		return nil, fs.ErrorCantCopy
	}
	headers := map[string]string{
		"Destination":            f.endpointURL + f.filePath(name),
		"Overwrite":              "T",
		"X-Ankole-Request-Id":    requestID,
		"X-Ankole-Expected-ETag": source.ankoleETag,
	}
	if baseline != "" {
		headers["If-Match"] = baseline
	} else {
		headers["If-None-Match"] = "*"
	}
	var response *http.Response
	var err error
	err = f.pacer.Call(func() (bool, error) {
		response, err = f.srv.Call(ctx, &rest.Opts{Method: "COPY", Path: f.filePath(src.Remote()), ExtraHeaders: headers, NoResponse: true})
		return f.shouldRetry(ctx, response, err)
	})
	if err != nil {
		return nil, ankoleError(response, err)
	}
	object := f.createObject(name, time.Time{}, 0)
	if err := object.ankoleResponse(response); err != nil {
		return nil, err
	}
	return object, nil
}

// Dynamic collections are not required to appear in their parent's listing.
func (f *Fs) AnkoleStat(ctx context.Context, name string) (fs.DirEntry, error) {
	if f.ankole == nil {
		return nil, fs.ErrorObjectNotFound
	}
	var result api.Multistatus
	_, err := f.srv.CallXML(ctx, &rest.Opts{Method: "PROPFIND", Path: f.filePath(name), ExtraHeaders: map[string]string{"Depth": "0"}}, nil, &result)
	if err != nil {
		if dav, ok := errors.AsType[*api.Error](err); ok && dav.StatusCode == 404 {
			return nil, fs.ErrorObjectNotFound
		}
		return nil, err
	}
	if len(result.Responses) != 1 {
		return nil, fs.ErrorObjectNotFound
	}
	response := &result.Responses[0]
	if itemIsDir(response) {
		return fs.NewDir(name, time.Time(response.Props.Modified)).SetID(response.Props.AnkoleNodeID), nil
	}
	o := f.createObject(name, time.Time(response.Props.Modified), response.Props.Size)
	if err := o.setMetaData(&response.Props); err != nil {
		return nil, err
	}
	return o, nil
}

func (o *Object) ankoleOpen(ctx context.Context, options []fs.OpenOption) (io.ReadCloser, error) {
	var resp *http.Response
	opts := rest.Opts{Method: "GET", Path: o.filePath(), Options: options, ExtraHeaders: map[string]string{"X-Ankole-Expected-ETag": o.ankoleETag}}
	resp, err := o.fs.srv.Call(ctx, &opts)
	if resp != nil && resp.StatusCode == 412 {
		return nil, syscall.ESTALE
	}
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}
