// Grid Wars shared renderer + drivers.
//
// Forked from cogame-bullwhip's client/renderer.js: the topband, scorebug,
// feed, scrubber, endscreen, name map, effects, both drivers and the
// replay pacing are that file's, with the conveyor STAGE replaced by the
// arena — a 30x30 toroidal board of tinted tiles, ticking bombs, corpses
// and four cog warriors — plus an appended Grid Wars block (the territory
// bar and the code pane).
//
// Fed by three drivers: the live /global websocket, the live /player
// websocket, and replay (from the static wasm bundle, which is the only
// thing that plays a recorded episode — there is no replay pod). All state
// derivation happens server-side / wasm-side; this file only draws frame
// objects:
//   {seats:[{name,seat,color,id,score,raw,tiles,peakTiles,energy,alive,x,y,
//            idle,kills,selfKills,line,action,banner,deathCause,faultLine,
//            faultText,origin,scriptLines,pending} x4 by SEAT],
//    grid:"900 chars" | gridDelta:[[cell,"c"]], bombs:[{x,y,fuse,seat}],
//    corpses:[[x,y]], blast:[[x,y]], round, rounds, tick, ticks,
//    roundsPlayed, phase:"submit|battle|roundEnd|done", focus,
//    scripts:[[line]] (submit frames only), series, log:[], gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seat 0
  // is red, 1 blue, 2 green, 3 yellow — the same order the warrior ids and
  // the sprite kits use.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var GRID = 30;
  var CELLS = GRID * GRID;
  // Timing of the arena's transient effects.
  var CLAIM_MS = 200;
  var BLAST_MS = 250;
  var DEAD_GRID = new Array(CELLS + 1).join(".");

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function signed(value) {
    var v = Math.round((value || 0) * 10) / 10;
    return (v > 0 ? "+" : "") + v.toFixed(1);
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Layout --------------------------------------------------------------

  // The arena is FIXED: 30x30, always rescaled to fit the canvas whole, so
  // the starter's zoom panel would be dead weight and is dropped entirely.
  // Everything else is measured from the cell size, so the scene reads at
  // 360px and at 1080p alike.
  function computeLayout(width, height) {
    var margin = 8;
    var cell = Math.max(4,
      Math.min((width - 2 * margin) / GRID, (height - 2 * margin) / GRID));
    var boardW = cell * GRID;
    return {
      width: width, height: height, cell: cell, board: boardW,
      x0: (width - boardW) / 2, y0: (height - boardW) / 2,
      scale: Math.max(0.5, Math.min(2, cell / 21))
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var scale = L.scale;
    var fx = view.effects || {};
    var grid = view.grid || DEAD_GRID;

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    ctx.fillRect(0, 0, w, h);

    // Board plate.
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.35)";
    ctx.fillRect(L.x0, L.y0, L.board, L.board);
    ctx.restore();

    drawTiles(ctx, L, grid, fx, now);
    drawGridLines(ctx, L);
    drawCorpses(ctx, L, view.corpses || [], scale);
    drawBombs(ctx, L, view.bombs || [], scale, now);
    drawBlast(ctx, L, view.blast || [], fx, now);

    // Warriors, painted after the board so a cog is never under a tile.
    for (var s = 0; s < seats.length; s++) {
      if (!seats[s]) continue;
      drawWarrior(ctx, images, L, s, seats[s], scale, view);
    }
  }

  function drawTiles(ctx, L, grid, fx, now) {
    var claimAt = fx.claimAt || null;
    for (var cell = 0; cell < CELLS; cell++) {
      var c = grid[cell];
      if (c === "." || c === undefined) continue;
      var seat = c.charCodeAt(0) - 49;   // '1' -> 0
      if (seat < 0 || seat > 3) continue;
      var hex = COLOR_HEX[seatColor(seat)];
      var x = L.x0 + (cell % GRID) * L.cell;
      var y = L.y0 + Math.floor(cell / GRID) * L.cell;
      var age = claimAt ? now - (claimAt[cell] || 0) : CLAIM_MS;
      var fresh = age < CLAIM_MS ? 1 - age / CLAIM_MS : 0;
      ctx.fillStyle = rgba(hex, 0.42 + 0.5 * fresh);
      ctx.fillRect(x, y, L.cell, L.cell);
    }
  }

  function drawGridLines(ctx, L) {
    ctx.save();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.07)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (var i = 0; i <= GRID; i++) {
      var p = Math.round(L.x0 + i * L.cell) + 0.5;
      ctx.moveTo(p, L.y0);
      ctx.lineTo(p, L.y0 + L.board);
      var q = Math.round(L.y0 + i * L.cell) + 0.5;
      ctx.moveTo(L.x0, q);
      ctx.lineTo(L.x0 + L.board, q);
    }
    ctx.stroke();
    ctx.restore();
  }

  function drawCorpses(ctx, L, corpses, scale) {
    ctx.save();
    ctx.strokeStyle = "rgba(20, 14, 9, 0.92)";
    ctx.lineWidth = Math.max(1.5, 2 * scale);
    ctx.lineCap = "round";
    corpses.forEach(function (pos) {
      var x = L.x0 + pos[0] * L.cell;
      var y = L.y0 + pos[1] * L.cell;
      var pad = L.cell * 0.22;
      ctx.beginPath();
      ctx.moveTo(x + pad, y + pad);
      ctx.lineTo(x + L.cell - pad, y + L.cell - pad);
      ctx.moveTo(x + L.cell - pad, y + pad);
      ctx.lineTo(x + pad, y + L.cell - pad);
      ctx.stroke();
    });
    ctx.restore();
  }

  function drawBombs(ctx, L, bombs, scale, now) {
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    bombs.forEach(function (bomb) {
      var hex = COLOR_HEX[seatColor(bomb.seat)];
      var cx = L.x0 + (bomb.x + 0.5) * L.cell;
      var cy = L.y0 + (bomb.y + 0.5) * L.cell;
      // Pulses faster as the fuse drops: 5 -> slow, 1 -> frantic.
      var period = 160 + 140 * Math.max(0, bomb.fuse);
      var pulse = 0.5 + 0.5 * Math.sin((now % period) / period * Math.PI * 2);
      var r = L.cell * (0.30 + 0.08 * pulse);
      ctx.fillStyle = "rgba(20, 14, 9, 0.92)";
      ctx.beginPath();
      ctx.arc(cx, cy, r + 1.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = hex;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.font = "700 " + Math.round(Math.max(8, L.cell * 0.52)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = INK;
      ctx.fillText(String(bomb.fuse), cx, cy + 0.5);
    });
    ctx.restore();
  }

  function drawBlast(ctx, L, blast, fx, now) {
    if (!blast.length) return;
    var age = typeof fx.blastAt === "number" ? now - fx.blastAt : 0;
    if (age > BLAST_MS) return;
    var alpha = 1 - age / BLAST_MS;
    ctx.save();
    ctx.fillStyle = "rgba(255, 250, 240, " + (0.35 + 0.55 * alpha) + ")";
    blast.forEach(function (pos) {
      ctx.fillRect(L.x0 + pos[0] * L.cell, L.y0 + pos[1] * L.cell,
        L.cell, L.cell);
    });
    ctx.restore();
  }

  function drawWarrior(ctx, images, L, seatIndex, seat, scale, view) {
    var color = seatColor(seatIndex);
    var cx = L.x0 + (seat.x + 0.5) * L.cell;
    var cy = L.y0 + (seat.y + 0.5) * L.cell;
    if (!seat.alive) return;   // the corpse cross is already on the board
    var size = L.cell * 1.9;
    var sprite = images["soldier_" + color + "_front.png"];
    ctx.save();
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, cx - size / 2, cy - size * 0.62, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(cx - L.cell * 0.4, cy - L.cell * 0.4, L.cell * 0.8,
        L.cell * 0.8);
    }
    ctx.restore();

    // Alias plate under the cog (the policy name spectator-side).
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.font = "600 " + Math.round(Math.max(9, 11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = ellipsize(ctx, seat.name || "", L.cell * 5);
    var pad = 3 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var by = cy + L.cell * 0.5;
    ctx.fillStyle = "rgba(18, 13, 9, 0.78)";
    ctx.fillRect(cx - bw / 2, by, bw, Math.max(11, 13 * scale));
    ctx.fillStyle = COLOR_HEX[color];
    ctx.fillText(label, cx, by + 1);
    ctx.restore();

    // Banner on a paper tag over the cog, when the seat wrote one.
    if (seat.banner && view.phase !== "battle") {
      drawTag(ctx, cx, cy - L.cell * 1.1, seat.banner, COLOR_HEX[color],
        scale, L.cell * 9);
    }
  }

  function drawTag(ctx, x, y, text, accent, scale, maxWidth) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = ellipsize(ctx, text.toUpperCase(), maxWidth);
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // A feed line is {at, round, cls, text}: `at` is the frame index it
  // becomes visible at (-1 = always, for the live views).
  function classOfLog(text) {
    if (/ kills /.test(text)) return "feed-kill";
    if (/own blast/.test(text)) return "feed-kill";
    if (/faulted at line/.test(text)) return "feed-fault";
    if (/idles out/.test(text)) return "feed-idle";
    if (/illegal move/.test(text)) return "feed-idle";
    if (/^Round /.test(text)) return "feed-round";
    if (/ submits /.test(text)) return "feed-submit";
    return "feed-line";
  }

  function feedFromFrames(frames, nameMap) {
    var lines = [];
    frames.forEach(function (frame, index) {
      (frame.log || []).forEach(function (text) {
        lines.push({
          at: index,
          round: frame.round || 0,
          cls: classOfLog(text),
          text: nameMap.text(text)
        });
      });
    });
    return lines;
  }

  function feedFromEvents(events, nameMap) {
    var lines = [];
    (events || []).forEach(function (event) {
      if (event.kind === "submit") {
        lines.push({
          at: -1, round: event.round, cls: "feed-submit",
          text: nameMap.seat(event.seat) + " submits a " +
            (event.lines || 0) + "-line warrior" +
            (event.compileError ? " (rejected: " + event.compileError + ")" :
              "")
        });
      } else if (event.kind === "battle") {
        var stats = event.stats || [];
        var best = 0;
        stats.forEach(function (s, i) {
          if (s.raw > stats[best].raw) best = i;
        });
        stats.forEach(function (s, i) {
          if (s.deathCause === "fault") {
            lines.push({ at: -1, round: event.round, cls: "feed-fault",
              text: nameMap.seat(i) + "'s warrior faulted at line " +
                s.faultLine + ": " + s.faultText });
          } else if (s.deathCause === "idle") {
            lines.push({ at: -1, round: event.round, cls: "feed-idle",
              text: nameMap.seat(i) + " idles out at tick " + s.deathTick });
          } else if (s.deathCause === "bomb") {
            lines.push({ at: -1, round: event.round, cls: "feed-kill",
              text: nameMap.seat(i) + " is blown off the board at tick " +
                s.deathTick });
          }
        });
        if (stats.length) {
          lines.push({ at: -1, round: event.round, cls: "feed-round",
            text: "Round " + event.round + " — " + nameMap.seat(best) + " " +
              stats[best].tiles + " tiles, " + signed(stats[best].roundScore) });
        }
      } else if (event.kind === "end") {
        lines.push({ at: -1, round: event.round, cls: "feed-end",
          text: "Final — " + event.round + " round" +
            (event.round === 1 ? "" : "s") + " played" +
            (event.text === "deadline" ? ", stopped by the episode clock" :
              "") });
      }
    });
    return lines;
  }

  // Renders the transcript grouped into one section per round.
  // `limit` (replay) is the frame index playback has reached; pass
  // undefined for live views.
  function renderFeed(element, lines, nameMap, limit) {
    if (!element) return;
    var live = limit === undefined;
    var html = "";
    var lastRound = null;
    lines.forEach(function (line) {
      if (line.round !== lastRound) {
        html += '<div class="feed-round-head">ROUND ' + line.round + "</div>";
        lastRound = line.round;
      }
      var future = !live && line.at > limit;
      html += '<div class="feed-line ' + line.cls +
        (future ? " feed-future" : "") + '">' + escapeHtml(line.text) +
        "</div>";
    });
    if (element.dataset.html === html) return;
    element.dataset.html = html;
    element.innerHTML = html;
    if (live) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var nodes = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < nodes.length; l++) {
      if (!nodes[l].classList.contains("feed-future")) target = nodes[l];
    }
    if (target) {
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns the frame stream into transient view effects: when each cell was
  // claimed (it flashes) and when the last blast went off (it flares).
  function makeEffects() {
    var claimAt = new Float64Array(CELLS);
    var blastAt = null;
    return {
      absorb: function (frame, prevGrid, grid, quiet) {
        var now = Date.now();
        if (!quiet && prevGrid && grid) {
          for (var cell = 0; cell < CELLS; cell++) {
            if (grid[cell] !== prevGrid[cell] && grid[cell] !== ".") {
              claimAt[cell] = now;
            }
          }
        }
        blastAt = (frame && frame.blast && frame.blast.length && !quiet) ?
          now : null;
      },
      reset: function () {
        claimAt = new Float64Array(CELLS);
        blastAt = null;
      },
      view: function () {
        return { effects: { claimAt: claimAt, blastAt: blastAt } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(frame) {
    if (!frame) return "";
    var parts = [];
    parts.push("R" + (frame.round || 0) + " / " + (frame.rounds || 0));
    if (frame.gameDone) {
      parts.push("FINAL");
    } else if (frame.phase === "submit") {
      parts.push("SUBMITTING");
    } else if (frame.phase === "roundEnd") {
      parts.push("ROUND OVER");
    } else {
      parts.push("TICK " + (frame.tick || 0) + " / " + (frame.ticks || 0));
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, frame, nameMap, onFocus) {
    if (!container || !frame || !frame.seats) return;
    var html = "";
    frame.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) +
        (seat.alive ? "" : " dead") + '" data-seat="' + index + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !frame.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + escapeHtml(signed(seat.score)) +
        "</span>" +
        '<span class="plate-tiles">' + (seat.tiles || 0) + " tiles</span>" +
        '<span class="plate-energy">' + (seat.energy || 0) + " energy</span>" +
        // The kill count only earns its space once there is one: at four
        // plates across an embedded stage the NAME must never be the thing
        // that shrinks.
        (seat.kills ? '<span class="plate-label">' + seat.kills + " kill" +
          (seat.kills === 1 ? "" : "s") + "</span>" : "") +
        (seat.faultLine ? '<span class="plate-fault">FAULT</span>' :
          (!seat.alive ? '<span class="plate-dead">DEAD</span>' : "")) +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
      if (onFocus) {
        Array.prototype.forEach.call(
          container.querySelectorAll(".plate"), function (plate) {
            plate.onclick = function () {
              onFocus(parseInt(plate.dataset.seat, 10));
            };
          });
      }
    }
  }

  function reasonLine(results) {
    if (results.reason === "deadline") {
      return "episode deadline: scored on " + (results.rounds || 0) + " of " +
        (results.maxRounds || results.rounds || 0) + " rounds";
    }
    return "";
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap, lastReason) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " " +
        (lastReason === "lastStanding" ? "IS THE LAST WARRIOR STANDING" :
          "OUTPAINTED THE FIELD") :
      "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">rounds won</span>' +
      '<span class="end-head">tiles</span>' +
      '<span class="end-head">kills</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(signed(scores[i]))) +
        cell((results.roundsWon || [])[i] || 0) +
        cell((results.tiles || [])[i] || 0) +
        cell((results.kills || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Grid reconstruction -------------------------------------------------

  // `grid` is written in full on keyframes only (every 25th tick, every
  // submit frame, every roundEnd frame and frame 0) and as `gridDelta`
  // otherwise, which is the difference between a ~200KB replay payload and
  // a ~2MB one. A seek walks back to the nearest keyframe and replays the
  // deltas forward.
  function makeGridReader(frames) {
    var cacheIndex = -1;
    var cacheGrid = null;
    function apply(grid, frame) {
      if (frame.grid) return frame.grid.split("");
      (frame.gridDelta || []).forEach(function (change) {
        grid[change[0]] = change[1];
      });
      return grid;
    }
    return function (index) {
      if (index < 0 || index >= frames.length) return DEAD_GRID.split("");
      if (cacheIndex === index && cacheGrid) return cacheGrid;
      if (cacheIndex === index - 1 && cacheGrid) {
        cacheGrid = apply(cacheGrid.slice(), frames[index]);
        cacheIndex = index;
        return cacheGrid;
      }
      var start = index;
      while (start > 0 && !frames[start].grid) start -= 1;
      var grid = (frames[start].grid || DEAD_GRID).split("");
      for (var k = start + 1; k <= index; k++) grid = apply(grid, frames[k]);
      cacheGrid = grid;
      cacheIndex = index;
      return grid;
    };
  }

  function scriptsAt(frames, index) {
    for (var i = Math.min(index, frames.length - 1); i >= 0; i--) {
      if (frames[i] && frames[i].scripts) return frames[i].scripts;
    }
    return [[], [], [], []];
  }

  // ---- Drivers -------------------------------------------------------------

  function frameToView(frame, grid, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(frame.seats, nameMap);
    view.grid = grid;
    view.bombs = frame.bombs || [];
    view.corpses = frame.corpses || [];
    view.blast = frame.blast || [];
    view.round = frame.round || 0;
    view.rounds = frame.rounds || 0;
    view.tick = frame.tick || 0;
    view.ticks = frame.ticks || 0;
    view.phase = frame.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame ({seat:{...}}) becomes a four-seat frame with
  // the own seat filled in so the same scene draws.
  function playerFrameToFrame(data) {
    if (data.seats && data.seats.length) return data;
    var seats = [];
    for (var i = 0; i < 4; i++) {
      seats.push({
        name: "Seat " + i, seat: i, color: i, id: i + 1, score: 0,
        tiles: (data.tiles || [])[i] || 0, energy: 0, alive: true,
        x: 0, y: 0, kills: 0, line: 0, pending: false
      });
    }
    if (typeof data.slot === "number" && data.seat) {
      seats[data.slot].name = data.name;
      seats[data.slot].score = data.seat.score || 0;
      seats[data.slot].tiles = data.seat.tiles || 0;
    }
    return {
      seats: seats, grid: DEAD_GRID, bombs: [], corpses: [], blast: [],
      round: data.round, rounds: data.rounds, tick: -1, ticks: data.ticks,
      roundsPlayed: data.roundsPlayed, phase: data.done ? "done" : "submit",
      gameDone: data.done, reason: data.reason, scripts: [[], [], [], []],
      log: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen, terrbar,
    //           codepane, assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var prevGrid = null;
      var focus = 0;
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToFrame(data);
            if (latest) {
              nameMap = makeNameMap(
                (latest.seats || []).map(function (s) { return s.name; }),
                data.policyNames);
              var grid = (latest.grid || DEAD_GRID).split("");
              effects.absorb(latest, prevGrid, grid, false);
              prevGrid = grid;
              latest.gridChars = grid;
              renderFeed(options.feed,
                feedFromEvents(data.events, nameMap), nameMap, undefined);
              if (options.clock) {
                options.clock.textContent = matchHeader(latest);
              }
              updateScorebug(options.scorebug, latest, nameMap,
                function (seat) { focus = seat; });
              buildGridWarsTerritory(options.terrbar, latest, nameMap);
              buildGridWarsCode(options.codepane, latest,
                latest.scripts || [], focus, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap, "");
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = frameToView(latest, latest.gridChars ||
            DEAD_GRID.split(""), nameMap, effects, {
              done: !!(latest.done || latest.gameDone)
            });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round and one
  // LABELLED, CLICKABLE beat button per submission, kill, fault, idle
  // death, round end and the final frame.
  function buildScrub(container, frames, beats, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var total = Math.max(frames.length, 1);
    var blockStarts = [];
    var lastBlock = null;
    frames.forEach(function (frame, i) {
      var block = frame.round || 0;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : frames.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / total * 100) + "%";
      span.style.width = ((endIdx - startIdx) / total * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / total * 100) + "%";
        container.appendChild(sep);
      }
    });
    beats.forEach(function (beat) {
      container.appendChild(
        markGridWarsBeat(beat.at / total, beat.kind, beat.seat, beat.label,
          function () { onSeek(beat.at); }));
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * (frames.length - 1)));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      if (evt.target && evt.target.classList.contains("beat-marker")) return;
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = index / total * 100;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, terrbar, codepane, assetBase, payload}
    var payload = options.payload;
    var frames = payload.frames || [];
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var gridAt = makeGridReader(frames);
    var beats = computeGridWarsBeats(frames, nameMap);
    var feedLines = feedFromFrames(frames, nameMap);
    var lastRoundReason = "";
    (payload.results && payload.results.roundReasons || []).forEach(
      function (r) { lastRoundReason = r; });
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var focusOverride = null;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, frames, beats, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= frames.length - 1) setIndex(0, true);
        };
      }

      function currentFrame() {
        return frames[Math.min(Math.max(index, 0), frames.length - 1)] ||
          { seats: [], phase: "", round: 0 };
      }

      function setIndex(next, jumped) {
        var previous = index;
        index = Math.max(0, Math.min(next, Math.max(frames.length - 1, 0)));
        scrub.update(index);
        var prevGrid = jumped ? null : gridAt(previous);
        var grid = gridAt(index);
        if (jumped) effects.reset();
        effects.absorb(currentFrame(), prevGrid, grid, jumped);
        renderFeed(options.feed, feedLines, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " +
            Math.max(frames.length - 1, 0);
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentFrame());
        }
        var focus = focusOverride === null ?
          (currentFrame().focus || 0) : focusOverride;
        updateScorebug(options.scorebug, currentFrame(), nameMap,
          function (seat) { focusOverride = seat; });
        buildGridWarsTerritory(options.terrbar, currentFrame(), nameMap);
        buildGridWarsCode(options.codepane, currentFrame(),
          scriptsAt(frames, index), focus, nameMap);
        // Every seek re-evaluates the endcard, so scrubbing below the last
        // frame always dismisses it.
        updateEndscreen(options.endscreen, payload.results,
          index >= frames.length - 1 && frames.length > 0, nameMap,
          lastRoundReason);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is looking at: a tick is quick, a new
        // program needs long enough to read in the code pane.
        var shown = currentFrame();
        var stepMs = shown.phase === "submit" ? 1200 :
          shown.phase === "roundEnd" ? 1500 :
          shown.phase === "done" ? 1500 : 40;
        if (playing && index < frames.length - 1 &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < frames.length - 1;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = frameToView(currentFrame(), gridAt(index), nameMap,
          effects, { done: index >= frames.length - 1 && frames.length > 0 });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  // ==========================================================================
  // GRID WARS additions to the inherited cogame-bullwhip chrome.
  //
  // Naming guard: nothing below reuses a name the chrome above defines, so
  // no hoisted function here can shadow a chrome alias (tandem, 2026-08-23).
  // tests/test_viewer.nim asserts the two name sets are disjoint.
  // ==========================================================================

  // One labelled, clickable beat button. `fraction` is its position along
  // the track, `kind` is one of submit/kill/fault/idle/roundend/end and has
  // its own CSS rule in the appended chrome block.
  function markGridWarsBeat(fraction, kind, seat, label, onSeek) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "beat-marker " + kind +
      (typeof seat === "number" && seat >= 0 ?
        " seat" + (seat % COLORS.length) : "");
    button.style.left = (fraction * 100) + "%";
    button.title = label;
    button.setAttribute("aria-label", label);
    button.onclick = function (evt) {
      evt.stopPropagation();
      onSeek();
    };
    return button;
  }

  function computeGridWarsBeats(frames, nameMap) {
    var beats = [];
    frames.forEach(function (frame, index) {
      var round = frame.round || 0;
      if (frame.phase === "submit") {
        var seat = typeof frame.focus === "number" ? frame.focus : -1;
        var seats = frame.seats || [];
        beats.push({
          at: index, kind: "submit", seat: seat,
          label: "R" + round + " · " + nameMap.seat(seat) + " submits " +
            ((seats[seat] && seats[seat].scriptLines) || 0) + " lines"
        });
        return;
      }
      if (frame.phase === "roundEnd" || frame.phase === "done") {
        var best = 0;
        (frame.seats || []).forEach(function (s, i) {
          if (s.raw > (frame.seats[best].raw || 0)) best = i;
        });
        beats.push({
          at: index, kind: "roundend", seat: best,
          label: "R" + round + " · " + nameMap.seat(best) + " " +
            ((frame.seats[best] && frame.seats[best].tiles) || 0) + " tiles"
        });
        return;
      }
      var before = frames[index - 1];
      if (!before || !before.seats) return;
      (frame.seats || []).forEach(function (seat, i) {
        var was = before.seats[i];
        if (!was || !was.alive || seat.alive) return;
        var kind = seat.deathCause === "fault" ? "fault" :
          seat.deathCause === "idle" ? "idle" : "kill";
        var label = kind === "fault" ?
          "R" + round + " t" + frame.tick + " · " + nameMap.seat(i) +
            " faults at line " + seat.faultLine :
          kind === "idle" ?
          "R" + round + " t" + frame.tick + " · " + nameMap.seat(i) +
            " idles out" :
          "R" + round + " t" + frame.tick + " · " + nameMap.seat(i) +
            " is blown off the board";
        beats.push({ at: index, kind: kind, seat: i, label: label });
      });
    });
    if (frames.length) {
      beats.push({
        at: frames.length - 1, kind: "end", seat: -1, label: "Final"
      });
    }
    return beats;
  }

  // The territory bar: one stacked segment per seat, width proportional to
  // tiles, with a grey remainder for unclaimed ground.
  function buildGridWarsTerritory(container, frame, nameMap) {
    if (!container || !frame || !frame.seats) return;
    var html = "";
    var claimed = 0;
    frame.seats.forEach(function (seat) { claimed += seat.tiles || 0; });
    frame.seats.forEach(function (seat, index) {
      var pct = (seat.tiles || 0) / CELLS * 100;
      if (pct <= 0) return;
      html += '<div class="terrseg ' + seatColor(index) + '" style="width:' +
        pct.toFixed(2) + '%" title="' +
        escapeHtml(nameMap ? nameMap.seat(index) : seat.name) + " " +
        (seat.tiles || 0) + ' tiles">' +
        (pct > 6 ? (seat.tiles || 0) : "") + "</div>";
    });
    var free = Math.max(0, CELLS - claimed) / CELLS * 100;
    html += '<div class="terrseg free" style="width:' + free.toFixed(2) +
      '%">' + (free > 10 ? (CELLS - claimed) + " free" : "") + "</div>";
    if (container.dataset.html === html) return;
    container.dataset.html = html;
    container.innerHTML = html;
  }

  // The code pane: the focused seat's warrior for the current round, with
  // the line it is executing THIS frame lit, scrolled to keep it in view.
  // This is the idea's "see the program think".
  function buildGridWarsCode(container, frame, scripts, focus, nameMap) {
    if (!container || !frame || !frame.seats) return;
    var seat = frame.seats[focus] || frame.seats[0];
    if (!seat) return;
    var lines = (scripts && scripts[focus]) || [];
    var origin = (seat.origin || "").toLowerCase();
    var html = '<div id="codehead" class="' + seatColor(focus) + '">' +
      escapeHtml(clampName(nameMap ? nameMap.seat(focus) : seat.name)) +
      (origin ? '<span class="chip ' + origin + '">' +
        escapeHtml(origin) + "</span>" : "") +
      (seat.faultLine ? '<span class="chip fault">line ' + seat.faultLine +
        ": " + escapeHtml(seat.faultText || "") + "</span>" : "") +
      "</div>";
    var now = frame.phase === "battle" ? (seat.line || 0) : 0;
    lines.forEach(function (line, index) {
      var number = index + 1;
      html += '<div class="codeline' + (number === now ? " now" : "") + '">' +
        '<span class="ln">' + number + "</span>" +
        '<span class="src">' + escapeHtml(line) + "</span></div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
    var active = container.querySelector(".codeline.now");
    if (active) {
      var top = active.offsetTop - container.offsetTop;
      if (top < container.scrollTop ||
          top > container.scrollTop + container.clientHeight - 40) {
        container.scrollTop = Math.max(0, top - container.clientHeight * 0.4);
      }
    }
  }

  window.GridWarsRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
