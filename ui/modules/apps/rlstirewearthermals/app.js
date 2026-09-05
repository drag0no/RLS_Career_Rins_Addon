angular.module("beamng.apps")
  .directive("rlsTireWearThermals", [function () {
    return {
      template:
        '<div class="rls-ttw bngApp">' +
          '<link type="text/css" rel="stylesheet" href="/ui/modules/apps/rlstirewearthermals/app.css">' +
          '<div class="rls-ttw-toolbar">' +
            '<button type="button" class="rls-ttw-toggle" ng-click="toggleDetailed($event)" title="Toggle detailed wear zones">' +
              '<span class="rls-ttw-wrench" aria-hidden="true"></span>' +
              '<span class="rls-ttw-switch" ng-class="{ on: detailed }"></span>' +
            '</button>' +
            '<div class="rls-ttw-meta">' +
              '<div class="rls-ttw-title">TIRE THERMALS & WEAR</div>' +
              '<div class="rls-ttw-provider" ng-class="{ warn: providerWarn }" ng-bind="providerLabel"></div>' +
            '</div>' +
            '<div class="rls-ttw-mode" ng-bind="detailed ? \'Detailed\' : \'Basic\'"></div>' +
          '</div>' +
          '<canvas class="rls-ttw-canvas" width="260" height="280"></canvas>' +
        '</div>',
      replace: true,
      restrict: "EA",
      link: function (scope, element) {
        var streamNames = ["RlsTireWearThermals", "TyreWearThermals"];
        StreamsManager.add(streamNames);

        scope.detailed = false;
        scope.providerLabel = "Waiting for vehicle";
        scope.providerWarn = false;
        scope.toggleDetailed = function ($event) {
          if ($event) $event.stopPropagation();
          scope.detailed = !scope.detailed;
          if (lastStreams) draw(lastStreams);
        };

        var root = element[0];
        var canvas = root.querySelector("canvas");
        var ctx = canvas.getContext("2d");
        var lastStreams = null;
        var toolbarHeight = 34;
        var lastTelemetryAt = 0;
        var lastRlsPayload = null;
        var lastLegacyPayload = null;
        var lastRlsSession = null;
        var lastRlsSequence = null;
        var telemetryStale = false;
        var staleAfterMs = 3000;
        var staleTimer = window.setInterval(function () {
          if (!lastTelemetryAt || Date.now() - lastTelemetryAt <= staleAfterMs) return;
          lastTelemetryAt = 0;
          telemetryStale = true;
          draw({});
          if (!scope.$$phase) scope.$evalAsync();
        }, 500);

        scope.$on("$destroy", function () {
          window.clearInterval(staleTimer);
          StreamsManager.remove(streamNames);
        });

        function syncCanvasSize(width, height) {
          var w = Math.max(1, Math.floor(width || root.clientWidth || 260));
          var h = Math.max(1, Math.floor(height || root.clientHeight || 280));
          toolbarHeight = Math.max(28, Math.floor((root.querySelector(".rls-ttw-toolbar") || {}).offsetHeight || 34));
          canvas.width = w;
          canvas.height = Math.max(1, h - toolbarHeight);
          canvas.style.width = w + "px";
          canvas.style.height = canvas.height + "px";
        }

        scope.$on("app:resized", function (event, data) {
          syncCanvasSize(data && data.width, data && data.height);
          if (lastStreams) draw(lastStreams);
        });
        syncCanvasSize(root.clientWidth, root.clientHeight);

        function clamp(value, low, high) {
          return Math.min(Math.max(Number(value) || 0, low), high);
        }

        // Front → mid → rear, left before right. Numeric tokens keep multi-axle order stable.
        function wheelPositionRank(wheel) {
          var name = String(wheel && wheel.name || "").toUpperCase();
          var isFront = name.charAt(0) === "F" || name.indexOf("FRONT") !== -1;
          var isMid = name.charAt(0) === "M" || name.indexOf("MID") !== -1 || name.indexOf("CENTER") !== -1;
          var isRear = name.charAt(0) === "R" || name.indexOf("REAR") !== -1;
          var isLeft = name.charAt(name.length - 1) === "L" || name.indexOf("LEFT") !== -1;
          var isRight = name.charAt(name.length - 1) === "R" || name.indexOf("RIGHT") !== -1;
          var numMatch = name.match(/(\d+)/);
          var num = numMatch ? Number(numMatch[1]) : 0;
          var axleRank = isFront ? 0 : (isMid ? 40 + num : (isRear ? 80 + num : 60 + num));
          var sideRank = isLeft ? 0 : (isRight ? 1 : 2);
          return axleRank * 10 + sideRank;
        }

        function tempHue(temperature, working) {
          var ratio = clamp(temperature / Math.max(working, 1), 0, 1.6);
          return clamp(235 - ratio * 190, 0, 235);
        }

        function tempColor(temperature, working, alpha) {
          return "hsla(" + tempHue(temperature, working) + ", 82%, 56%, " + (alpha == null ? 1 : alpha) + ")";
        }

        function channelToLinear(channel) {
          var c = channel / 255;
          return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        }

        function hslToRgb(h, s, l) {
          var sat = clamp(s, 0, 1);
          var light = clamp(l, 0, 1);
          var hue = ((h % 360) + 360) % 360;
          var c = (1 - Math.abs(2 * light - 1)) * sat;
          var x = c * (1 - Math.abs((hue / 60) % 2 - 1));
          var m = light - c / 2;
          var r = 0, g = 0, b = 0;
          if (hue < 60) { r = c; g = x; }
          else if (hue < 120) { r = x; g = c; }
          else if (hue < 180) { g = c; b = x; }
          else if (hue < 240) { g = x; b = c; }
          else if (hue < 300) { r = x; b = c; }
          else { r = c; b = x; }
          return {
            r: Math.round((r + m) * 255),
            g: Math.round((g + m) * 255),
            b: Math.round((b + m) * 255)
          };
        }

        function relativeLuminance(rgb) {
          return 0.2126 * channelToLinear(rgb.r) + 0.7152 * channelToLinear(rgb.g) + 0.0722 * channelToLinear(rgb.b);
        }

        // Pick dark/light ink from the tire fill so % stays readable on cold blues and hot yellows.
        function contrastInkForFill(temperature, working, flat) {
          if (flat) return { fill: "#ffffff", stroke: "rgba(70, 10, 10, 0.85)" };
          var rgb = hslToRgb(tempHue(temperature, working), 0.82, 0.56);
          var bright = relativeLuminance(rgb) > 0.45;
          return bright
            ? { fill: "#101218", stroke: "rgba(255, 255, 255, 0.72)" }
            : { fill: "#ffffff", stroke: "rgba(0, 0, 0, 0.72)" };
        }

        function drawContrastText(text, x, y, font, ink, strokeWidth) {
          ctx.font = font;
          ctx.lineJoin = "round";
          ctx.miterLimit = 2;
          ctx.lineWidth = strokeWidth == null ? 3.5 : strokeWidth;
          ctx.strokeStyle = ink.stroke;
          ctx.strokeText(text, x, y);
          ctx.fillStyle = ink.fill;
          ctx.fillText(text, x, y);
        }

        function wearColor(condition, flat) {
          if (flat) return "#ff6b6b";
          if (condition < 20) return "#ffb347";
          if (condition < 45) return "#ffe08a";
          return "#9fe38f";
        }

        function roundRect(x, y, w, h, r) {
          var radius = Math.min(r, w / 2, h / 2);
          ctx.beginPath();
          ctx.moveTo(x + radius, y);
          ctx.arcTo(x + w, y, x + w, y + h, radius);
          ctx.arcTo(x + w, y + h, x, y + h, radius);
          ctx.arcTo(x, y + h, x, y, radius);
          ctx.arcTo(x, y, x + w, y, radius);
          ctx.closePath();
        }

        function ringWearValues(wheel, condition) {
          // Prefer explicit per-ring wear when a provider supplies it; otherwise use overall condition.
          var source = null;
          if (Array.isArray(wheel.wear) && wheel.wear.length >= 3) source = wheel.wear;
          else if (Array.isArray(wheel.condition_rings) && wheel.condition_rings.length >= 3) source = wheel.condition_rings;
          else if (Array.isArray(wheel.wear_percents) && wheel.wear_percents.length >= 3) source = wheel.wear_percents;
          if (!source) return [condition, condition, condition];
          return [
            clamp(source[0], 0, 100),
            clamp(source[1], 0, 100),
            clamp(source[2], 0, 100)
          ];
        }

        function drawTireChrome(x, y, w, h, col, cols, flat) {
          var pad = 4;
          var bodyX = x + pad;
          var bodyY = y + pad;
          var bodyW = w - pad * 2;
          var bodyH = h - pad * 2;
          var radius = 8;

          // Hub attachments when this axle has a left/right pair (Weight Distribution style).
          if (cols > 1) {
            var nubW = Math.max(4, Math.min(7, w * 0.08));
            var nubH = Math.max(18, Math.min(42, h * 0.34));
            var nubY = y + (h - nubH) / 2;
            ctx.fillStyle = "#f2f2f2";
            if (col === 0) ctx.fillRect(x + w - nubW, nubY, nubW, nubH);
            if (col === cols - 1) ctx.fillRect(x, nubY, nubW, nubH);
            if (col > 0 && col < cols - 1) {
              ctx.fillRect(x, nubY, nubW, nubH);
              ctx.fillRect(x + w - nubW, nubY, nubW, nubH);
            }
          }

          ctx.fillStyle = "rgba(20, 24, 30, 0.72)";
          roundRect(bodyX, bodyY, bodyW, bodyH, radius);
          ctx.fill();
          ctx.strokeStyle = flat ? "#ff5555" : "rgba(242, 242, 242, 0.92)";
          ctx.lineWidth = 2;
          roundRect(bodyX, bodyY, bodyW, bodyH, radius);
          ctx.stroke();

          return { x: bodyX, y: bodyY, w: bodyW, h: bodyH, r: radius };
        }

        function drawBasicTile(wheel, x, y, w, h, col, cols) {
          var condition = clamp(wheel.condition, 0, 100);
          var temperatures = Array.isArray(wheel.temp) ? wheel.temp : [0, 0, 0, 0];
          var working = Math.max(Number(wheel.working_temp) || 85, 1);
          var avgTemp = Number(wheel.avg_temp);
          if (!isFinite(avgTemp)) {
            avgTemp = ((Number(temperatures[0]) || 0) + (Number(temperatures[1]) || 0) + (Number(temperatures[2]) || 0)) / 3;
          }
          var flat = wheel.flat === true || condition <= 0;
          var body = drawTireChrome(x, y, w, h, col, cols, flat);
          var fillH = body.h * clamp(condition / 100, 0, 1);
          var fillTop = body.y + body.h - fillH;
          var ink = contrastInkForFill(avgTemp, working, flat);
          var darkInk = { fill: "#ffffff", stroke: "rgba(0, 0, 0, 0.7)" };

          ctx.save();
          roundRect(body.x, body.y, body.w, body.h, body.r);
          ctx.clip();
          ctx.fillStyle = flat ? "rgba(255, 85, 85, 0.78)" : tempColor(avgTemp, working, 0.92);
          ctx.fillRect(body.x, fillTop, body.w, fillH);
          ctx.restore();

          ctx.textAlign = "center";
          ctx.textBaseline = "middle";
          var nameY = body.y + 16;
          drawContrastText(String(wheel.name || ""), body.x + body.w / 2, nameY, 'bold 13px "Lucida Console", monospace',
            nameY >= fillTop ? ink : darkInk, 3);

          var tempY = body.y + body.h * 0.42;
          drawContrastText(flat ? "FLAT" : Math.round(avgTemp) + "°", body.x + body.w / 2, tempY,
            '11px "Lucida Console", monospace', tempY >= fillTop ? ink : darkInk, 3);

          var pctY = body.y + body.h * 0.78;
          drawContrastText(flat ? "—" : Math.ceil(condition) + "%", body.x + body.w / 2, pctY,
            'bold 22px "Lucida Console", monospace', pctY >= fillTop ? ink : darkInk, 4.5);
          ctx.textBaseline = "alphabetic";
          ctx.textAlign = "left";
        }

        function drawDetailedTile(wheel, x, y, w, h, col, cols) {
          var condition = clamp(wheel.condition, 0, 100);
          var temperatures = Array.isArray(wheel.temp) ? wheel.temp : [0, 0, 0, 0];
          var working = Math.max(Number(wheel.working_temp) || 85, 1);
          var flat = wheel.flat === true || condition <= 0;
          var wears = ringWearValues(wheel, condition);
          var body = drawTireChrome(x, y, w, h, col, cols, flat);
          var labels = ["I", "C", "O"];
          var headerInk = { fill: "#ffffff", stroke: "rgba(0, 0, 0, 0.7)" };

          ctx.textAlign = "left";
          ctx.textBaseline = "middle";
          drawContrastText(String(wheel.name || ""), body.x + 8, body.y + 14,
            'bold 12px "Lucida Console", monospace', headerInk, 3);
          ctx.textAlign = "right";
          drawContrastText(flat ? "FLAT" : Math.ceil(condition) + "%", body.x + body.w - 8, body.y + 14,
            'bold 12px "Lucida Console", monospace',
            flat
              ? { fill: "#ff8f8f", stroke: "rgba(0, 0, 0, 0.75)" }
              : { fill: wearColor(condition, false), stroke: "rgba(0, 0, 0, 0.75)" },
            3);

          var barTop = body.y + 26;
          var barBottomPad = 16;
          var barHeight = Math.max(18, body.h - (barTop - body.y) - barBottomPad);
          var barGap = 4;
          var barWidth = (body.w - 16 - barGap * 2) / 3;

          for (var ring = 0; ring < 3; ring++) {
            var bx = body.x + 8 + ring * (barWidth + barGap);
            var temperature = Number(temperatures[ring]) || 0;
            var wear = wears[ring];
            var fillHeight = barHeight * clamp(wear / 100, 0, 1);
            var fillTop = barTop + barHeight - fillHeight;
            var ink = contrastInkForFill(temperature, working, flat);
            var darkInk = { fill: "#ffffff", stroke: "rgba(0, 0, 0, 0.7)" };
            var cx = bx + barWidth / 2;

            ctx.fillStyle = "rgba(0,0,0,0.45)";
            roundRect(bx, barTop, barWidth, barHeight, 3);
            ctx.fill();

            ctx.fillStyle = flat ? "rgba(255,85,85,0.85)" : tempColor(temperature, working, 0.95);
            ctx.fillRect(bx, fillTop, barWidth, fillHeight);

            ctx.textAlign = "center";
            var labelY = barTop + 8;
            drawContrastText(labels[ring], cx, labelY, '9px "Lucida Console", monospace',
              labelY >= fillTop ? ink : darkInk, 2.5);

            var pctY = barTop + barHeight / 2;
            drawContrastText(flat ? "0%" : Math.ceil(wear) + "%", cx, pctY,
              'bold 11px "Lucida Console", monospace', pctY >= fillTop ? ink : darkInk, 3.5);

            var tempY = barTop + barHeight - 6;
            drawContrastText(Math.round(temperature) + "°", cx, tempY, '9px "Lucida Console", monospace',
              tempY >= fillTop ? ink : darkInk, 2.5);
          }
          ctx.textAlign = "left";
          ctx.textBaseline = "alphabetic";
        }

        function layoutColumns(wheelCount) {
          // Keep a 2-column axle layout (FL/FR …) and grow rows for extra axles.
          // Odd counts still use 2 columns so a lone center/rear tire sits on its own row.
          if (wheelCount <= 1) return 1;
          return 2;
        }

        function draw(streams) {
          lastStreams = streams || {};
          var rls = lastStreams.RlsTireWearThermals || null;
          var legacy = lastStreams.TyreWearThermals || null;
          var externalSelected = rls && rls.provider && rls.provider.source === "external";
          var dataStream = externalSelected && legacy ? legacy : (rls && rls.data && rls.data.length ? rls : legacy);
          var wheels = dataStream && Array.isArray(dataStream.data) ? dataStream.data.slice() : [];
          wheels.sort(function (left, right) {
            var positionDifference = wheelPositionRank(left) - wheelPositionRank(right);
            if (positionDifference !== 0) return positionDifference;
            return String(left && left.name || "").localeCompare(String(right && right.name || ""));
          });

          var provider = rls && rls.provider;
          scope.providerLabel = provider
            ? ((provider.source === "external" ? "External" : "RLS") + " " + (provider.version || ""))
            : (legacy ? "External" : "Waiting for vehicle");
          scope.providerWarn = !!(provider && provider.integrated === false);

          ctx.clearRect(0, 0, canvas.width, canvas.height);
          ctx.fillStyle = "rgba(8, 10, 13, 0.35)";
          ctx.fillRect(0, 0, canvas.width, canvas.height);

          if (!wheels.length) {
            ctx.fillStyle = "rgba(255,255,255,0.65)";
            ctx.font = '11px "Lucida Console", monospace';
            ctx.textAlign = "left";
            ctx.fillText("No tire telemetry", 10, 22);
            return;
          }

          var columns = layoutColumns(wheels.length);
          var gapX = 8;
          var gapY = 8;
          var inset = 8;
          var rows = Math.ceil(wheels.length / columns);
          var cardWidth = (canvas.width - inset * 2 - gapX * (columns - 1)) / columns;
          var cardHeight = Math.max(72, (canvas.height - inset * 2 - gapY * (rows - 1)) / rows);

          wheels.forEach(function (wheel, index) {
            var col = index % columns;
            var row = Math.floor(index / columns);
            // Center a leftover tire on the final row (e.g. 5-wheel layouts).
            var wheelsOnRow = Math.min(columns, wheels.length - row * columns);
            var rowOffsetX = wheelsOnRow < columns
              ? ((columns - wheelsOnRow) * (cardWidth + gapX)) / 2
              : 0;
            var x = inset + rowOffsetX + col * (cardWidth + gapX);
            var y = inset + row * (cardHeight + gapY);
            if (scope.detailed) drawDetailedTile(wheel, x, y, cardWidth, cardHeight, col, wheelsOnRow);
            else drawBasicTile(wheel, x, y, cardWidth, cardHeight, col, wheelsOnRow);
          });
        }

        function drawCachedTelemetry() {
          var streams = {};
          if (lastRlsPayload) streams.RlsTireWearThermals = lastRlsPayload;
          if (lastLegacyPayload) streams.TyreWearThermals = lastLegacyPayload;
          draw(telemetryStale ? {} : streams);
        }

        scope.$on("streamsUpdate", function (event, streams) {
          var rls = streams && streams.RlsTireWearThermals;
          var legacy = streams && streams.TyreWearThermals;
          var acceptedRls = false;
          var acceptedLegacy = false;
          if (rls) {
            var sequence = Number(rls.sequence);
            var session = String(rls.session || "legacy");
            var sequenced = Number.isFinite(sequence);
            if (!sequenced || session !== lastRlsSession || lastRlsSequence == null || sequence > lastRlsSequence) {
              lastRlsPayload = rls;
              lastRlsSession = session;
              lastRlsSequence = sequenced ? sequence : null;
              lastTelemetryAt = Date.now();
              telemetryStale = false;
              acceptedRls = true;
            }
          }
          // StreamsManager may retain an empty/cached legacy entry even while
          // the bundled provider is selected. Only let the legacy stream act
          // as a heartbeat when it is actually the selected data source.
          var selectedRls = acceptedRls ? rls : lastRlsPayload;
          var externalSelected = selectedRls && selectedRls.provider && selectedRls.provider.source === "external";
          if (legacy && (externalSelected || !selectedRls)) {
            lastLegacyPayload = legacy;
            lastTelemetryAt = Date.now();
            telemetryStale = false;
            acceptedLegacy = true;
          }
          // streamsUpdate also carries unrelated stream frames. Redrawing those
          // as an empty tire payload made the canvas flash between valid packets.
          if (!acceptedRls && !acceptedLegacy) return;
          var previousLabel = scope.providerLabel;
          var previousWarn = scope.providerWarn;
          drawCachedTelemetry();
          if ((scope.providerLabel !== previousLabel || scope.providerWarn !== previousWarn) && !scope.$$phase) {
            scope.$digest();
          }
        });
      }
    };
  }]);
