# ScreenWren development preferences

- After making changes and completing relevant verification, terminate running
  ScreenWren app instances, install the current rebuilt app with
  `./install-app.sh --no-build`, and reopen `/Applications/ScreenWren.app`.
  Andrew has requested this as the default workflow; do not ask for another
  restart confirmation. Use the saved local signing identity and timestamp mode;
  do not replace them with ad-hoc signing for an interactive installation.
