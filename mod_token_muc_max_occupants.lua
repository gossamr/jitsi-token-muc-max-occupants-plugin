-- Token-based MUC Max Occupants
-- This module looks for a field in JWT tokens called "max_occ".
-- If there are already that many occupants in the room, they will be refused entry.
-- Participants in muc_access_whitelist will not be counted for the
-- max occupants value (values are jids like recorder@jitsi.meeet.example.com).
-- This module is configured under the muc component that is used for jitsi-meet

local log = module._log;
local json = require "cjson";
local basexx = require "basexx";
local um_is_admin = require "core.usermanager".is_admin;
local bare_jid = require "util.jid".bare;
local split_jid = require "util.jid".split;
local st = require "util.stanza";
local it = require "util.iterators";

log('info', 'Loaded token max muc occupants plugin');
local whitelist = module:get_option_set("muc_access_whitelist");

local function is_admin(jid)
  return um_is_admin(jid, module.host);
end

local function count_keys(t)
  return it.count(it.keys(t));
end

local function get_max_occupants(auth_token)
  if auth_token then
    -- Extract token body and decode it
    local dotFirst = auth_token:find("%.");
    if dotFirst then
      local dotSecond = auth_token:sub(dotFirst + 1):find("%.");
      if dotSecond then
        local bodyB64 = auth_token:sub(dotFirst + 1, dotFirst + dotSecond - 1);
        local body = json.decode(basexx.from_url64(bodyB64));
        if body["max_occ"] then
          return body["max_occ"];
        else
          -- This hard-codes a room size limit in the absence of a token value
          return 35;
        end;
      end;
    end;
  end;
end;

local function check_for_max_occupants(event)
  local room, origin, stanza = event.room, event.origin, event.stanza;

  local actor = stanza.attr.from;
  local user, domain, res = split_jid(actor);
  local jid = bare_jid(actor);

  --no user object means no way to check for max occupants
  if user == nil then
    return;
  end

  if is_admin(jid) then
    return;
  end

  -- If we're a whitelisted user joining the room, don't bother checking the max
  -- occupants.
  if whitelist and whitelist:contains(domain) or whitelist:contains(user..'@'..domain) then
    return;
  end

  if origin and room and not room._jid_nick[actor] then
    local count = count_keys(room._occupants);
    local slots = get_max_occupants(origin.auth_token);

    -- If there is no whitelist, just check the count.
    if not whitelist and count >= slots then
      module:log("info", "Attempt to enter a maxed out MUC");
      origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
      return true;
    end

    -- TODO: Are Prosody hooks atomic, or is this a race condition?
    -- For each person in the room that's not on the whitelist, subtract one
    -- from the count.
    for _, occupant in room:each_occupant() do
      user, domain, res = split_jid(occupant.bare_jid);
      if not whitelist:contains(domain) and not whitelist:contains(user..'@'..domain) then
        slots = slots - 1
      end
    end

    -- If the room is full (<0 slots left), error out.
    if slots <= 0 then
      module:log("info", "Attempt to enter a maxed out MUC");
      origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
      return true;
    end
  end
end

module:hook("muc-occupant-pre-join", check_for_max_occupants, 10);
