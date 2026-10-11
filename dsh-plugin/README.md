# dsh-emacs-bridge (DSH plugin)

The DeepSeek Harness half of
[dsh-emacs-bridge](https://github.com/seewhydee/dsh-emacs-bridge), a two-way
bridge between GNU Emacs and a running DSH session.

Install it with DSH's plugin manager:

```sh
dsh plugin --profile web add dsh-emacs-bridge
```

Then open DSH's **Plugins** page, click the `dsh-emacs-bridge` entry, and use
**Install Emacs package** to install the `dsh-bridge.el` this package carries
into your Emacs.  The plugin and the Emacs package are released in lockstep and
must be the same version, so upgrade both halves together.

Overview, manual and offline installation, usage, and the permissions this
bridge grants:
<https://github.com/seewhydee/dsh-emacs-bridge#installation>.

This package is free software under the GNU General Public License version 3 or
later; see [LICENSE](LICENSE).
