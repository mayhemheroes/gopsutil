// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This is the OSS-Fuzz harness for shirou/gopsutil (OSS-Fuzz project
// "gopsutil", target FuzzTest). It is a NATIVE Go fuzz harness:
//
//	func FuzzTest(f *testing.F)   -> built with go-118-fuzz-build.
//
// It lives in package process. OSS-Fuzz copies this file into ./process/ and
// adds a register.go that imports the AdamKorcz testing shim; mayhem/build.sh
// replicates that exactly. The harness writes the fuzzed bytes to a
// /proc-style <pid>/limits file (HOST_PROC=".") and runs the limits parser
// RlimitUsageWithContext -> fillFromLimitsWithContext, which tokenises each
// line with strings.Fields and indexes str[len(str)-1]. The fuzzed surface is
// gopsutil's /proc/<pid>/limits text parser.

package process

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func init() {
	os.Setenv("HOST_PROC", ".")
}

func FuzzTest(f *testing.F) {
	f.Fuzz(func(t *testing.T, data []byte) {
		p := &Process{Pid: int32(1)}
		if len(data) < 5 {
			return
		}
		err := os.Mkdir("1", 0750)
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll("1")
		file := filepath.Join(".", "1", "limits")
		err = os.WriteFile(file, data, 0666)
		if err != nil {
			panic(err)
		}
		p.RlimitUsageWithContext(context.Background(), true)
	})
}
