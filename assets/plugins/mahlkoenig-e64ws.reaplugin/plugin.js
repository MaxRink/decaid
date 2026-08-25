/* Mahlkönig E64 WS local plugin.
 *
 * The plugin only calls the host's typed grinder bridge. It never opens a raw
 * socket and it never calls the Mahlkönig cloud. The host owns the WSS
 * connection, response correlation, certificate policy, and capability gate.
 */

function createPlugin(host) {
  "use strict";

  const ID = "mahlkoenig-e64ws.reaplugin";
  const VERSION = "0.1.0";
  const LOCAL_API_URL = "http://127.0.0.1:8080/api/v1";
  const ACTIONS = new Set([
    "Stop", "StartGrindManual", "StartGrindGbw", "StartGrindGbt",
    "StartCalibration", "StartTara", "SaveLog", "ResetLog",
    "SetFanTemperatureCtrlEnabled", "CalibrateFan1", "CalibrateFan2",
    "ToggleBacklightPower", "SetBacklightBrightness", "SetFan1Duty",
    "SetFan2Duty", "SetAgsaTargetDdValue", "StopAgsa", "CalibrateDdSensor",
    "ResetDriverConfig", "SetLanguage", "StartEnduranceTest",
    "StopEnduranceTest", "SetSetupWizardState", "AddBrewEvent",
    "EspFlashApp", "EspEraseFlash", "EspReset", "NozzleLightRunStandby",
    "NozzleLightStop", "RcTopLeftClick", "RcTopLeftLong", "RcTopLeftPress",
    "RcTopLeftRelease", "RcBottomLeftClick", "RcRotaryClick", "RcRotaryLong",
    "RcRotaryDouble", "RcRotary", "GbsCreateReport"
  ]);

  // Normal finite-input GBS model recovered from libNgxUi.so
  // HEM-HSG-HMI-S01 V01.16-24. These are deliberately kept in the plugin as
  // a revisioned model: they are not silently treated as universal coffee
  // science or as proof of the physical coarser/finer DD direction.
  const GBS = {
    sampleLimit: 6,
    v1ErrorWindow: 0.5,
    v1Center: 5,
    v1CorrectionScale: 32768,
    v1CorrectionOffset: 0.2,
    v1CorrectionLimit: 5,
    v1MinState: 1,
    v1Quantum: 0.2,
    v1HysteresisFactor: 0.8,
    ddChangeLimit: 500,
    learningErrorLimit: 3,
    v3NearThreshold: 2,
    v3FarThreshold: 5,
    v3MediumWidth: 3,
    v2PredictionWeight: 0.9,
    v3v4PredictionWeight: 0.6,
    outputScale: 10,
    regressionVarianceLimit: 0.001,
    regressionFallbackSlope: -2,
    regressionSlopeMax: -0.5
  };

  const DIAL_IN_ROWS = {
    "e64/light": [3.5, -20], "e64/medium": [3.5, 0], "e64/dark": [3.5, 20],
    "e65/light": [4, -20], "e65/medium": [4, 0], "e65/dark": [4, 20],
    "e80/light": [6, -20], "e80/medium": [6, 0], "e80/dark": [6, 20]
  };

  function finite(value, name) {
    if (typeof value !== "number" || !isFinite(value)) {
      throw new Error(name + " must be a finite number");
    }
    return value;
  }

  function cxxRound(value) {
    value = finite(value, "value");
    return value >= 0 ? Math.floor(value + 0.5) : Math.ceil(value - 0.5);
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value));
  }

  function appendPoint(points, x, y) {
    points.push({ x: finite(x, "sample.x"), y: finite(y, "sample.y") });
    while (points.length > GBS.sampleLimit) points.shift();
  }

  function firmwareRegression(points, targetY) {
    if (!points.length) throw new Error("GBS regression needs one sample");
    targetY = finite(targetY, "targetY");
    let meanX = 0;
    let meanDelta = 0;
    points.forEach(function (point) {
      meanX += finite(point.x, "sample.x");
      meanDelta += finite(point.y, "sample.y") - targetY;
    });
    meanX /= points.length;
    meanDelta /= points.length;
    let slope = GBS.regressionFallbackSlope;
    if (points.length > 1) {
      let variance = 0;
      let covariance = 0;
      points.forEach(function (point) {
        const dx = point.x - meanX;
        variance += dx * dx;
        covariance += dx * ((point.y - targetY) - meanDelta);
      });
      if (variance > GBS.regressionVarianceLimit) {
        slope = covariance / variance;
        if (slope > GBS.regressionSlopeMax) slope = GBS.regressionSlopeMax;
      }
    }
    return meanX - meanDelta / slope;
  }

  function blendV2(current, prediction) {
    current = finite(current, "current");
    prediction = finite(prediction, "prediction");
    const blended = current +
      (prediction - current) * GBS.v2PredictionWeight;
    // The recovered branch bounds same-sign interpolation.  Its explicit
    // weighted-sum branch is retained for zero/opposite-sign host inputs.
    if (current * prediction > 0) {
      return clamp(blended, Math.min(current, prediction), Math.max(current, prediction));
    }
    return 0.1 * current + 0.9 * prediction;
  }

  function blendV3V4(current, prediction) {
    return finite(current, "current") +
      (finite(prediction, "prediction") - current) * GBS.v3v4PredictionWeight;
  }

  function outputTenths(value) {
    return cxxRound(finite(value, "GBS output") * GBS.outputScale);
  }

  function hystereticQuantize(value, previous) {
    const current = finite(value, "GBS quantizer value");
    const band = GBS.v1Quantum * GBS.v1HysteresisFactor;
    if (previous === null || !isFinite(previous) ||
        current < previous - band || current > previous + band) {
      return cxxRound(current / GBS.v1Quantum) * GBS.v1Quantum;
    }
    return previous;
  }

  function gbsV1Adjust(gbs, actualSeconds, targetSeconds) {
    actualSeconds = finite(actualSeconds, "actualSeconds");
    targetSeconds = finite(targetSeconds, "targetSeconds");
    const records = gbs.records;
    if (!records.length) {
      for (let age = 0; age < 4; age++) records.push({ value: actualSeconds, age: age });
    } else {
      records.forEach(function (record) { record.age += 1; });
      for (let i = records.length - 1; i >= 0; i--) {
        if (records[i].age === 3) records.splice(i, 1);
      }
      records.push({ value: actualSeconds, age: 0 });
    }
    records.sort(function (a, b) { return a.value - b.value; });
    const central = (records[1].value + records[2].value) / 2;
    let state = Math.max(GBS.v1MinState, finite(gbs.state, "V1 state"));
    if (Math.abs(central - targetSeconds) <= GBS.v1ErrorWindow) {
      const output = gbs.outputTenths === null
        ? cxxRound(state / GBS.v1Quantum) * 2
        : gbs.outputTenths;
      gbs.outputTenths = output;
      return {
        algorithm: "GbS1", phase: "within-error-window", central: central,
        correction: 0, candidateDdDum: output, returnedDdDum: output,
        committed: false
      };
    }
    const denominator = Math.pow(central - GBS.v1Center, 3);
    if (denominator === 0) {
      return {
        algorithm: "GbS1", phase: "singular-central", central: central,
        correction: null, candidateDdDum: gbs.outputTenths,
        returnedDdDum: gbs.outputTenths, committed: false
      };
    }
    const correction = clamp(
      -((GBS.v1CorrectionScale / denominator) + GBS.v1CorrectionOffset) *
        (targetSeconds - central),
      -GBS.v1CorrectionLimit, GBS.v1CorrectionLimit
    );
    state = Math.max(GBS.v1MinState, state + correction);
    const previous = gbs.outputTenths === null ? null : gbs.outputTenths / 10;
    const quantized = hystereticQuantize(state, previous);
    const output = cxxRound(quantized * 10);
    gbs.state = state;
    gbs.outputTenths = output;
    return {
      algorithm: "GbS1", phase: "adjust", central: central,
      correction: correction, candidateDdDum: output, returnedDdDum: output,
      committed: true
    };
  }

  function commitGbs(gbs, result, actualMs, targetMs, toleranceMs, estimatedDdDum) {
    if (gbs.lastTargetDum === null) gbs.lastTargetDum = estimatedDdDum;
    if (gbs.lastAdjustmentDum === null) gbs.lastAdjustmentDum = estimatedDdDum;
    if (Math.abs(actualMs - targetMs) < Math.abs(toleranceMs)) {
      result.committed = false;
      result.returnedDdDum = gbs.lastAdjustmentDum;
      return result;
    }
    gbs.lastTargetDum = estimatedDdDum;
    gbs.lastAdjustmentDum = result.candidateDdDum;
    result.committed = true;
    result.returnedDdDum = result.candidateDdDum;
    return result;
  }

  function gbsV3V4Calculate(gbs, phase, actualMs, targetMs, estimatedDdDum, setpointDdDum) {
    const actualSeconds = actualMs * 0.001;
    const targetSeconds = targetMs * 0.001;
    const estimatedUm = estimatedDdDum * 0.1;
    const setpointUm = setpointDdDum * 0.1;
    if (phase !== "far") appendPoint(gbs.history, setpointUm, actualSeconds);
    const effective = estimatedUm * actualSeconds;
    if (gbs.filteredDdTimesBrew === null) gbs.filteredDdTimesBrew = effective;
    else gbs.filteredDdTimesBrew = effective + gbs.filterRetention *
      (gbs.filteredDdTimesBrew - effective);
    const hyperbolic = gbs.filteredDdTimesBrew / targetSeconds;
    const linear = gbs.history.length < 2 ? hyperbolic :
      blendV3V4(setpointUm, firmwareRegression(gbs.history, targetSeconds));
    const factor = phase === "far" ? gbs.farFactor :
      (phase === "mid" ? gbs.midFactor : gbs.nearFactor);
    return outputTenths(hyperbolic + (linear - hyperbolic) * factor);
  }

  function gbsV3Adjust(gbs, input) {
    const actualMs = input.actualMs;
    const targetMs = input.targetMs;
    const estimated = input.estimatedDdDum;
    if (gbs.lastTargetDum !== null && gbs.lastAdjustmentDum !== null &&
        Math.abs(estimated - gbs.lastTargetDum) > GBS.ddChangeLimit) {
      gbs.lastTargetDum = estimated;
      return { algorithm: "GbS3", phase: "cancel", candidateDdDum: gbs.lastAdjustmentDum,
        returnedDdDum: gbs.lastAdjustmentDum, committed: false, locked: true };
    }
    const error = Math.abs(actualMs - targetMs) * 0.001;
    let phase;
    if (error <= gbs.nearThreshold && gbs.history.length > 2) {
      phase = "near";
      gbs.holdCyclesRemaining = gbs.holdCyclesSetting;
    } else if (gbs.holdCyclesRemaining > 0) {
      gbs.holdCyclesRemaining -= 1;
      phase = "near";
    } else if (error <= (gbs.keepMediumInterval ? gbs.nearThreshold + GBS.v3MediumWidth : GBS.v3FarThreshold)) {
      phase = "mid";
    } else {
      phase = "far";
      gbs.history = [];
    }
    const candidate = gbsV3V4Calculate(gbs, phase, actualMs, targetMs, estimated, input.setpointDdDum);
    return commitGbs(gbs, { algorithm: "GbS3", phase: phase, candidateDdDum: candidate },
      actualMs, targetMs, input.toleranceMs, estimated);
  }

  function gbsV2Adjust(gbs, input, body) {
    if (Array.isArray(body.points)) {
      // A caller may restore the transparent host replay state for testing,
      // but every normal adjustment still appends exactly one new sample.
      gbs.points = body.points.map(function (point) {
        return { x: finite(point.x, "point.x"), y: finite(point.y, "point.y") };
      }).slice(-GBS.sampleLimit);
    }
    appendPoint(gbs.points, input.setpointDdDum * 0.1, input.actualMs * 0.001);
    const prediction = firmwareRegression(gbs.points, input.targetMs * 0.001);
    const candidate = outputTenths(
      blendV2(input.setpointDdDum * 0.1, prediction)
    );
    if (gbs.lastResultDum === null) gbs.lastResultDum = input.estimatedDdDum;
    if (Math.abs(input.actualMs - input.targetMs) < Math.abs(input.toleranceMs)) {
      return {
        algorithm: "GbS2", phase: "regression", candidateDdDum: candidate,
        returnedDdDum: gbs.lastResultDum, committed: false
      };
    }
    gbs.lastResultDum = candidate;
    return {
      algorithm: "GbS2", phase: "regression", candidateDdDum: candidate,
      returnedDdDum: candidate, committed: true
    };
  }

  function gbsDdEffAdjust(gbs, initialDdDum, calls, reset) {
    if (reset || gbs.initialDdDum === null) {
      gbs.initialDdDum = initialDdDum;
      gbs.index = 0;
    }
    const count = Math.max(1, Math.trunc(numberOr(calls, 1)));
    const offsets = [0, -200, 200];
    const sequence = [];
    for (let i = 0; i < count; i++) {
      sequence.push(gbs.initialDdDum + offsets[Math.floor(gbs.index / 6) % offsets.length]);
      gbs.index += 1;
    }
    return {
      algorithm: "DdEff", phase: "measurement", sequence: sequence,
      candidateDdDum: sequence[sequence.length - 1],
      returnedDdDum: sequence[sequence.length - 1], committed: false,
      index: gbs.index
    };
  }

  function gbsV4Adjust(gbs, input) {
    const actualMs = input.actualMs;
    const targetMs = input.targetMs;
    const estimated = input.estimatedDdDum;
    if (gbs.lastTargetDum !== null && gbs.lastAdjustmentDum !== null &&
        Math.abs(estimated - gbs.lastTargetDum) > GBS.ddChangeLimit) {
      gbs.lastTargetDum = estimated;
      return { algorithm: "GbS4", phase: "cancel", candidateDdDum: gbs.lastAdjustmentDum,
        returnedDdDum: gbs.lastAdjustmentDum, committed: false, locked: true };
    }
    const error = Math.abs(actualMs - targetMs) * 0.001;
    if (error < GBS.learningErrorLimit && gbs.history.length > 2) {
      gbs.lastTargetDum = estimated;
      if (gbs.lastAdjustmentDum === null) {
        return { algorithm: "GbS4", phase: "near-without-adjustment", candidateDdDum: null,
          returnedDdDum: null, committed: false, locked: true };
      }
      return { algorithm: "GbS4", phase: "near", candidateDdDum: gbs.lastAdjustmentDum,
        returnedDdDum: gbs.lastAdjustmentDum, committed: false, locked: true };
    }
    let phase;
    if (gbs.holdCyclesRemaining > 0) {
      gbs.holdCyclesRemaining -= 1;
      phase = "near";
    } else if (error <= GBS.v3FarThreshold) {
      phase = "mid";
    } else {
      phase = "far";
      gbs.history = [];
    }
    const candidate = gbsV3V4Calculate(gbs, phase, actualMs, targetMs, estimated, input.setpointDdDum);
    return commitGbs(gbs, { algorithm: "GbS4", phase: phase, candidateDdDum: candidate },
      actualMs, targetMs, input.toleranceMs, estimated);
  }

  function dialInProposal(weightMg, model, roast) {
    weightMg = finite(weightMg, "weightMg");
    if (weightMg < 0) throw new Error("weightMg must not be negative");
    const key = String(model || "").toLowerCase() + "/" + String(roast || "").toLowerCase();
    const row = DIAL_IN_ROWS[key];
    if (!row) throw new Error("no decoded dial-in row for " + key);
    return Math.trunc(row[1] + row[0] * weightMg * 0.001 + 0.5);
  }

  function runGbs(body) {
    body = body || {};
    const selected = String(body.algorithm || state.gbsAlgorithm || "GbS1");
    const actualMs = numberOr(body.actualBrewTimeMs,
      numberOr(body.actualBrewTimeSeconds, NaN) * 1000);
    const targetMs = numberOr(body.targetBrewTimeMs,
      numberOr(body.targetBrewTimeSeconds, state.targetBrewTimeSeconds) * 1000);
    const estimated = numberOr(body.estimatedDdDum, numberOr(body.currentDdDum, NaN));
    const setpoint = numberOr(body.setpointDdDum, estimated);
    const tolerance = numberOr(body.toleranceMs, 1000);
    if (!isFinite(estimated)) throw new Error("GBS DD inputs are required");
    if (selected === "DdEff") {
      return gbsDdEffAdjust(state.gbs.ddEff, estimated, body.calls, body.reset === true);
    }
    if (!isFinite(actualMs) || !isFinite(targetMs)) throw new Error("GBS actual and target brew times are required");
    if (!isFinite(setpoint)) throw new Error("GBS DD inputs are required");
    if (selected === "GbS1" || !["GbS2", "GbS3", "GbS4"].includes(selected)) {
      const result = gbsV1Adjust(state.gbs.v1, actualMs * 0.001, targetMs * 0.001);
      result.selectedAlgorithm = selected;
      if (result.candidateDdDum === null) return result;
      return commitGbs(state.gbs.v1, result, actualMs, targetMs, tolerance, estimated);
    }
    const input = {
      actualMs: actualMs, targetMs: targetMs, estimatedDdDum: estimated,
      setpointDdDum: setpoint, toleranceMs: tolerance
    };
    if (selected === "GbS2") {
      return gbsV2Adjust(state.gbs.v2, input, body);
    }
    return selected === "GbS3" ? gbsV3Adjust(state.gbs.v3, input) : gbsV4Adjust(state.gbs.v4, input);
  }

  const state = {
    host: "",
    port: 9997,
    token: "",
    allowInsecureTls: false,
    scheme: "wss",
    pollIntervalSeconds: 3,
    enableActuation: false,
    targetBrewTimeSeconds: 28,
    flavor: "",
    gbsAlgorithm: "GbS1",
    gbs: {
      v1: { records: [], state: 1, outputTenths: null, lastTargetDum: null, lastAdjustmentDum: null },
      v2: { points: [], lastResultDum: null },
      v3: {
        history: [], farFactor: 0, midFactor: 0.5, nearFactor: 1,
        filterRetention: 0.5, holdCyclesSetting: 2, holdCyclesRemaining: 2,
        lastTargetDum: null, lastAdjustmentDum: null, filteredDdTimesBrew: null,
        nearThreshold: 2, keepMediumInterval: false
      },
      v4: {
        history: [], farFactor: 0, midFactor: 0.5, nearFactor: 1,
        filterRetention: 0.5, holdCyclesSetting: 2, holdCyclesRemaining: 2,
        lastTargetDum: null, lastAdjustmentDum: null, filteredDdTimesBrew: null
      },
      ddEff: { initialDdDum: null, index: 0 }
    },
    observedAt: null,
    connected: false,
    driverState: null,
    lastRecommendation: null,
    lastError: null,
    pollTimer: null,
    unloaded: false
  };

  function log(message) {
    try { host.log("[e64ws] " + String(message)); } catch (_) {}
  }

  function publish() {
    try {
      host.emit("state", {
        observedAt: state.observedAt,
        connected: state.connected,
        driverState: state.driverState,
        gbsAlgorithm: state.gbsAlgorithm,
        gbs: state.gbs,
        lastRecommendation: state.lastRecommendation,
        lastError: state.lastError
      });
    } catch (_) {}
  }

  function numberOr(value, fallback) {
    return typeof value === "number" && isFinite(value) ? value : fallback;
  }

  function connectionArguments(extra) {
    return Object.assign({
      host: state.host,
      port: state.port,
      token: state.token,
      allowInsecureTls: state.allowInsecureTls,
      scheme: state.scheme
    }, extra || {});
  }

  function configured() {
    return state.host.trim().length > 0 && state.token.trim().length > 0;
  }

  async function grinder(operation, extra) {
    if (!configured()) throw new Error("E64 host and token are not configured");
    return await host.grinder(operation, connectionArguments(extra));
  }

  function responseData(response) {
    if (!response || typeof response !== "object") return response;
    return response.data !== undefined ? response.data : response;
  }

  async function readState() {
    try {
      const response = await grinder("driver_state");
      state.driverState = responseData(response);
      state.connected = true;
      state.observedAt = new Date().toISOString();
      state.lastError = null;
      publish();
      return response;
    } catch (error) {
      state.connected = false;
      state.lastError = String(error && error.message || error);
      state.observedAt = new Date().toISOString();
      publish();
      throw error;
    }
  }

  function schedulePoll() {
    if (state.unloaded) return;
    const delay = Math.max(1, numberOr(state.pollIntervalSeconds, 3)) * 1000;
    state.pollTimer = setTimeout(async function () {
      state.pollTimer = null;
      try { await readState(); } catch (_) {}
      schedulePoll();
    }, delay);
  }

  function recommendation(actual, target, flavor) {
    const actualTime = numberOr(actual, NaN);
    const targetTime = numberOr(target, state.targetBrewTimeSeconds);
    const tolerance = 1;
    const text = String(flavor || "").trim().toLowerCase();
    const directions = [];
    const reasons = [];
    if (isFinite(actualTime)) {
      if (actualTime < targetTime - tolerance) {
        directions.push("finer");
        reasons.push("brew time is below target");
      } else if (actualTime > targetTime + tolerance) {
        directions.push("coarser");
        reasons.push("brew time is above target");
      }
    }
    if (["acidic", "sour", "sharp", "under-extracted"].some(function (word) {
      return text.indexOf(word) >= 0;
    })) {
      directions.push("finer");
      reasons.push("sensory input suggests under-extraction");
    }
    if (["bitter", "dry", "harsh", "over-extracted"].some(function (word) {
      return text.indexOf(word) >= 0;
    })) {
      directions.push("coarser");
      reasons.push("sensory input suggests over-extraction");
    }
    const distinct = Array.from(new Set(directions));
    const actionable = distinct.length === 1;
    return {
      direction: actionable ? distinct[0] : "none",
      confidence: actionable ? Math.min(0.95, 0.55 + 0.15 * Math.max(0, reasons.length - 1)) : 0,
      deltaSteps: 1,
      requiresConfirmation: true,
      actualBrewTimeSeconds: isFinite(actualTime) ? actualTime : null,
      targetBrewTimeSeconds: targetTime,
      reasons: reasons.length ? reasons : ["no actionable signal"],
      source: "decaid-conservative-model"
    };
  }

  function shotDurationSeconds(shot) {
    const measurements = shot && shot.measurements;
    if (!Array.isArray(measurements) || measurements.length < 2) return null;
    const first = measurements[0];
    const last = measurements[measurements.length - 1];
    const firstStamp = first && first.machine && first.machine.timestamp || first && first.timestamp;
    const lastStamp = last && last.machine && last.machine.timestamp || last && last.timestamp;
    const firstMs = Date.parse(String(firstStamp || ""));
    const lastMs = Date.parse(String(lastStamp || ""));
    if (!isFinite(firstMs) || !isFinite(lastMs) || lastMs < firstMs) return null;
    return (lastMs - firstMs) / 1000;
  }

  async function recommendFromShotId(shotId) {
    const response = await fetch(LOCAL_API_URL + "/shots/" + encodeURIComponent(String(shotId)));
    if (!response.ok) throw new Error("Decaid shot lookup failed: HTTP " + response.status);
    const shot = await response.json();
    const duration = shotDurationSeconds(shot);
    const driver = state.driverState && typeof state.driverState === "object"
      ? state.driverState : {};
    const estimatedDd = numberOr(
      driver.ddValueDum,
      numberOr(driver.ddSensorAngle,
        numberOr(driver.grindDdDum, NaN))
    );
    let result;
    if (duration !== null && isFinite(estimatedDd)) {
      result = runGbs({
        algorithm: state.gbsAlgorithm,
        actualBrewTimeSeconds: duration,
        targetBrewTimeSeconds: state.targetBrewTimeSeconds,
        estimatedDdDum: estimatedDd,
        setpointDdDum: estimatedDd,
        toleranceMs: 1000
      });
      result.flavor = state.flavor;
    } else {
      result = recommendation(duration, state.targetBrewTimeSeconds, state.flavor);
    }
    result.shotId = String(shotId);
    state.lastRecommendation = result;
    publish();
    return result;
  }

  function jsonResponse(status, value) {
    return {
      status: status,
      headers: { "content-type": "application/json" },
      body: JSON.stringify(value)
    };
  }

  function bodyObject(request) {
    return request && request.body && typeof request.body === "object" ? request.body : {};
  }

  async function handleHttpRequest(request) {
    const endpoint = request.endpoint;
    const body = bodyObject(request);
    try {
      if (endpoint === "status") {
        if (request.method === "GET") {
          try { await readState(); } catch (_) {}
        }
        return jsonResponse(200, {
          id: ID,
          version: VERSION,
          configured: configured(),
          connected: state.connected,
          observedAt: state.observedAt,
          driverState: state.driverState,
          gbsAlgorithm: state.gbsAlgorithm,
          gbs: state.gbs,
          lastRecommendation: state.lastRecommendation,
          lastError: state.lastError
        });
      }
      if (endpoint === "recommend") {
        if (body.algorithm || body.gbs === true) {
          const gbsResult = runGbs(body);
          state.lastRecommendation = gbsResult;
          publish();
          return jsonResponse(200, gbsResult);
        }
        const result = recommendation(
          body.actualBrewTimeSeconds,
          body.targetBrewTimeSeconds,
          body.flavor
        );
        state.lastRecommendation = result;
        publish();
        return jsonResponse(200, result);
      }
      if (endpoint === "gbsAdjust") {
        if (request.method !== "POST") return jsonResponse(405, { error: "POST required" });
        const gbsResult = runGbs(body);
        state.lastRecommendation = gbsResult;
        publish();
        return jsonResponse(200, gbsResult);
      }
      if (endpoint === "gbsReport") {
        if (request.method !== "GET" && request.method !== "POST") return jsonResponse(405, { error: "GET or POST required" });
        return jsonResponse(200, await grinder("gbs_report"));
      }
      if (endpoint === "action") {
        if (request.method !== "POST") return jsonResponse(405, { error: "POST required" });
        if (!state.enableActuation) return jsonResponse(403, { error: "Actuation is disabled in plugin settings" });
        const suffix = String(body.suffix || "");
        if (!ACTIONS.has(suffix)) return jsonResponse(400, { error: "Unknown recovered action suffix" });
        if (body.confirmed !== true) return jsonResponse(409, { error: "confirmed=true is required" });
        return jsonResponse(200, await grinder("action", {
          suffix: suffix,
          data: body.data && typeof body.data === "object" ? body.data : {},
          confirmed: true
        }));
      }
      return jsonResponse(404, { error: "Unknown endpoint" });
    } catch (error) {
      state.lastError = String(error && error.message || error);
      state.connected = false;
      publish();
      return jsonResponse(502, { error: state.lastError });
    }
  }

  return {
    id: ID,
    version: VERSION,
    onLoad(settings) {
      settings = settings || {};
      state.host = String(settings.Host || "");
      state.port = numberOr(settings.Port, 9997);
      state.token = String(settings.Token || "");
      state.allowInsecureTls = settings.AllowInsecureTls === true;
      state.scheme = String(settings.Transport || "wss");
      state.pollIntervalSeconds = Math.max(1, numberOr(settings.PollIntervalSeconds, 3));
      state.enableActuation = settings.EnableActuation === true;
      state.targetBrewTimeSeconds = numberOr(settings.TargetBrewTimeSeconds, 28);
      state.flavor = String(settings.Flavor || "");
      state.gbsAlgorithm = String(settings.GbsAlgorithm || "GbS1");
      state.gbs.v3.nearThreshold = GBS.v3NearThreshold;
      log("loaded; local-only transport enabled");
      schedulePoll();
    },
    onUnload() {
      state.unloaded = true;
      if (state.pollTimer !== null) clearTimeout(state.pollTimer);
      state.pollTimer = null;
    },
    onEvent(event) {
      if (!event) return;
      if (event.name === "shotStored" && event.payload && event.payload.id) {
        recommendFromShotId(event.payload.id).catch(function (error) {
          log("shot recommendation failed: " + String(error && error.message || error));
        });
      }
    },
    handleHttpRequest
  };
}
