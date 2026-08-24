## Grid Wars player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Grid Wars strategy), then idles until the final frame. All of
## the actual warrior-writing happens inside the game server, which sends
## this seat's prompt to Claude once a round.
##
## PLAYER_SCRIPTED=painter (or 1) registers the seat as the built-in
## spiral-painter warrior instead; `bomber` is the aggressive baseline and
## `sentry` the always-legal fallback. The server plays those
## deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <grid-wars-image> --name my-grid-wars \
##     --run /bin/gridwars-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Write a warrior that claims ground and stays alive. Paint every cell you
stand on, check before you move (a live bomb, a corpse or another warrior
blocks you), and turn rather than stall — 50 ticks in the same cell kills
you. Keep the program short enough that it always runs: a warrior that
faults on line 40 scores nothing, and survival is worth 100 tiles. Spend
energy on a bomb only when a rival is within a cell or two, or when a bomb
seals the gap into the region you are painting; remember a bomb is a wall
for five ticks and then scorches a plus of five cells, so never plant one
you are about to walk into. Read your diagnostics every round: a fault line
tells you exactly what to fix, a high blocked count means your movement
rule is wrong, and an idle death means you need a guaranteed move.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "grid-wars player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "grid-wars player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send only queues, so the
  ## game's quit(0) can outrun the flushed final frame. Without this the
  ## player container exits 1 and hosted certification reports
  ## player_error, intermittently.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "grid-wars player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "grid-wars player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " (warrior ", payload{"id"}.getInt(), ")"
          ## Re-deliver the prompt after the welcome, in case the first
          ## send raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "grid-wars player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "grid-wars player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "grid-wars player: socket closed (", error.msg, "), exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
