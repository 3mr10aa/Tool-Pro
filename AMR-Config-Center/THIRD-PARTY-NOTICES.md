# Third-party notices

The scripts in `config-scripts/` are reviewed and adapted by AMR Utility from the following MIT-licensed projects. Their logic is kept where noted in each file header. Copyright stays with the upstream authors.

| Script group | Upstream | Reviewed commit | Copyright |
|---|---|---|---|
| WindowsUpdate-Reset, WindowsUpdate-Undo | https://github.com/ChrisTitusTech/winutil (functions/public/Invoke-WPFFixesUpdate.ps1) | 70c23c80641d7370532af2f619b2842658600842 | Copyright (c) 2022 CT Tech Group LLC |
| NFS-Enable, NFS-Disable, OpenSSH-Enable, OpenSSH-Disable | https://github.com/ChrisTitusTech/winutil (NFS and SSH server setup commands) | 70c23c80641d7370532af2f619b2842658600842 | Copyright (c) 2022 CT Tech Group LLC |
| CttProfile-Install, CttProfile-Remove | https://github.com/ChrisTitusTech/powershell-profile (setup.ps1) | daa7ba227573de2a97739f15762f2ec231817925 | Copyright (c) 2025 Chris Titus |

The CTT install script downloads the upstream profile (pinned to the commit above) and an oh-my-posh theme from https://github.com/JanDeDobbeleer/oh-my-posh (MIT). Those files are downloaded at run time, not stored here.

## MIT License (applies to the upstream code above)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source license files: https://github.com/ChrisTitusTech/winutil/blob/main/LICENSE and https://github.com/ChrisTitusTech/powershell-profile/blob/main/LICENSE (read 2026-11-27).
