local urlparse = require("socket.url")
local socket = require("socket")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")
local html_entities = require("htmlEntities")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local item_type = nil
local item_name = nil
local item_value = nil

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false
local status_code = 0
local content_type = ""

local discovered_outlinks = {}
local discovered_items = {}
local discovered_stash = {}
local bad_items = {}
local ids = {}

local retry_url = false
local context = {}
local not_found_count = 0

local item_patterns = {
  ["^https?://wenwen%.sogou%.com/z/q([0-9]+)%.htm"] = "question",
  ["^https?://wenwen%.sogou%.com/question/q([0-9]+)%.htm"] = "question",
  ["^https?://wenwen%.sogou%.com/question/%?qid=([0-9]+)"] = "question",
  ["^https?://wenwen%.sogou%.com/question/%?[^#]+&qid=([0-9]+)"] = "question",
  ["^https?://wenwen%.sogou%.com/wapi/ms/question%-commonlist%?qid=([0-9]+)"] = "question",
  ["^https?://wenwen%.sogou%.com/wapi/ms/question%-commonlist%?[^#]+&qid=([0-9]+)"] = "question",
  ["^https?://wenwen%.sogou%.com/user/center/?%?uid=([^&#]+)"] = "user",
  ["^https?://wenwen%.sogou%.com/user/center/?%?[^#]+&uid=([^&#]+)"] = "user",
  ["^https?://wenwen%.sogou%.com/cate/tag/?%?tag_?[Ii]d=([^&#]*)"] = "tag",
  ["^https?://wenwen%.sogou%.com/cate/tag/?%?[^#]+&tag_?[Ii]d=([^&#]*)"] = "tag",
  ["^https?://(pic%.wenwen%.soso%.com/[^#]+)"] = "media",
  ["^https?://(img%.sogoucdn%.com/[^#]+)"] = "media",
  ["^https?://(hhy%.sogoucdn%.com/[^#]+)"] = "media",
  ["^https?://(cache%.soso%.com/[^#]+)"] = "media",
  ["^https?://([a-zA-Z0-9%.%-]+%.qlogo%.cn/[^#]+)"] = "media",
}

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file, "rb"))
    local body = f:read("*all")
    f:close()
    return body
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
    target[item] = true
    return true
  end
  return false
end

percent_encode_url = function(newurl)
  return string.gsub(newurl, "(.)", function(c)
    local b = string.byte(c)
    if b < 32 or b > 126 then
      return string.format("%%%02X", b)
    end
    return c
  end)
end

find_item = function(url)
  for pattern, type_ in pairs(item_patterns) do
    local value = string.match(url, pattern)
    if value then
      if type_ ~= "media" then
        value = percent_encode_url(urlparse.unescape(value))
      end
      if type_ == "tag" and not string.match(value, "^[0-9]+$") then
        return nil
      end
      return {
        ["value"]=value,
        ["type"]=type_
      }
    end
  end
  if string.match(url, "^https?://wenwen%.sogou%.com/cate/tag/?$")
    or string.match(url, "^https?://wenwen%.sogou%.com/cate/tag/?[%?#]") then
    return {
      ["value"]="0",
      ["type"]="tag"
    }
  end
end

local function get_count(data)
  local count = 0
  for _ in pairs(data) do
    count = count + 1
  end
  return count
end

finish_item = function()
  if not item_name or abortgrab then
    return nil
  end
  if not context["content_seen"] then
    abort_item()
    return nil
  end
  if item_type == "question" then
    if get_count(context["html_answers"]) ~= context["answer_total"] + get_count(context["best_answers"])
      or get_count(context["api_answers"]) ~= context["answer_total"]
      or context["api_end"] ~= context["answer_total"]
      or context["counts_changed"]
      or (
        context["answer_total"] > 5
        and context["ending_page"] ~= math.ceil(context["answer_total"] / 5)
      ) then
      abort_item()
    end
    for answer, data in pairs(context["api_answers"]) do
      if not context["html_answers"][answer]
        or context["best_answers"][answer]
        or data["comment_total"] > context["comments"][answer]["total"] then
        abort_item()
      end
    end
    for _, comments in pairs(context["comments"]) do
      if get_count(comments["ids"]) ~= comments["total"]
        or (comments["total"] % 5 == 3 and not comments["end_seen"]) then
        abort_item()
      end
    end
  elseif item_type == "user" then
    if not context["user_info"]
      or not context["user_badge"]
      or get_count(context["history"]) ~= context["history_total"] then
      abort_item()
    end
  end
end

set_item = function(url)
  if ids[url] then
    return nil
  end
  local found = find_item(url)
  if found then
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_name ~= item_name then
      finish_item()
      ids = {}
      context = {}
      context["entry_url"] = url
      if new_item_type ~= "media" then
        context["ajax_count"] = math.floor(socket.gettime() * 1000)
      end
      if new_item_type == "question" then
        context["html_answers"] = {}
        context["best_answers"] = {}
        context["comments"] = {}
        context["api_answers"] = {}
        context["api_totals"] = {}
      elseif new_item_type == "user" then
        context["history"] = {}
        context["trace_count"] = 0
      end
      item_value = new_item_value
      item_type = new_item_type
      ids[url] = true
      ids[urlparse.unescape(item_value)] = true
      abortgrab = false
      tries = 0
      retry_url = false
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parent)
  local lower = string.lower(url)
  if ids[url] then
    return true
  end

  for _, pattern in pairs({
    "^https?://[^/]+/submit/",
    "^https?://[^/]+/login/",
    "^https?://wenwenfeedapi%.sogou%.com/sgapi/related/",
    "^https?://cache%.soso%.com/qlogo/g%?",
    "^https?://wenwen%.sogou%.com/z/askquestion",
    "^https?://wenwen%.sogou%.com/question/ask%?",
    "^https?://wenwen%.sogou%.com/notfound",
    "^https?://wenwen%.sogou%.com/question/notfound",
    "^https?://[^/]*googletagmanager%.com/",
    "^https?://[^/]*googleadservices%.com/",
    "^https?://[^/]*gstatic%.com/prose/",
    "^https?://[^/]*facebook%.com/sharer/",
    "^https?://[^/]*facebook%.com/2008/fbml",
    "^https?://[^/]*w3%.org/2000/svg",
    "^https?://schema%.org/"
  }) do
    if string.match(lower, pattern) then
      return false
    end
  end

  local found = find_item(url)
  if found then
    local new_item = found["type"] .. ":" .. found["value"]
    if found["type"] == "tag" then
      discover_item(discovered_stash, new_item)
      return false
    end
    if new_item ~= item_name then
      discover_item(discovered_items, percent_encode_url(new_item))
      return false
    end
    if string.match(url, "[%?&]ch=")
      or string.match(url, "^https?://wenwen%.sogou%.com/z/") then
      return false
    end
    return true
  end

  if string.match(lower, "^https?://wenwen%.sogou%.com/cate/tag/?$")
    or string.match(lower, "^https?://wenwen%.sogou%.com/cate/tag/?[%?#]") then
    return false
  end

  if not (
    string.match(lower, "^https?://wenwen%.sogou%.com/")
    or string.match(lower, "^https?://wenwenfeedapi%.sogou%.com/")
  ) then
    discover_item(discovered_outlinks, string.match(percent_encode_url(url), "^([^%s]+)"))
    return false
  end

  if item_type == "question"
    and context["title"]
    and string.match(lower, "^https?://wenwenfeedapi%.sogou%.com/sgapi/related/hint%?")
    and string.match(url, "[%?&]key=([^&]+)") == context["title"] then
    return true
  end

  for _, pattern in pairs({
    "[%?&]question[Ii]d=([^&#]+)",
    "[%?&]qid=([^&#]+)",
    "[%?&]uid=([^&#]+)",
    "/q([0-9]+)%.htm"
  }) do
    for identifier in string.gmatch(url, pattern) do
      identifier = urlparse.unescape(identifier)
      if ids[identifier] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function(s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local history_start = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, body_data, referer)
    if not newurl then
      newurl = ""
    end
    newurl = html_entities.decode(decode_codepoint(newurl))
    newurl = string.gsub(newurl, "\\/", "/")
    newurl = string.match(newurl, "^%s*(.-)%s*$")
    newurl = string.gsub(newurl, " ", "%%20")
    newurl = fix_case(newurl)
    if not string.match(newurl, "^https?://") or string.match(newurl, "[%s\\\"<>]") then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = url
    while string.match(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    local key = ((body_data and "POST") or "GET") .. "\0" .. url_ .. "\0" .. (body_data or "")
    if not processed(key)
      and (body_data or not processed(url_))
      and allowed(url_) then
      local url_data = {
        url=url_,
        headers={}
      }
      if body_data then
        url_data["body_data"] = body_data
        url_data["method"] = "POST"
        url_data["headers"]["Content-Type"]="application/x-www-form-urlencoded; charset=UTF-8"
      end
      if string.match(url_, "^https://wenwen%.sogou%.com/wapi/") then
        url_data["headers"]["Accept"] = "application/json, text/javascript, */*; q=0.01"
        url_data["headers"]["X-Requested-With"] = "XMLHttpRequest"
        url_data["headers"]["Referer"] = referer or context["entry_url"]
        url_data["headers"]["Sec-Fetch-Dest"] = "empty"
        url_data["headers"]["Sec-Fetch-Mode"] = "cors"
        url_data["headers"]["Sec-Fetch-Site"] = "same-origin"
      elseif string.match(url_, "^https://wenwenfeedapi%.sogou%.com/") then
        url_data["headers"]["Accept"] = "application/json, text/javascript, */*; q=0.01"
        url_data["headers"]["Origin"] = "https://wenwen.sogou.com"
        url_data["headers"]["Referer"] = referer or context["entry_url"]
        url_data["headers"]["Sec-Fetch-Dest"] = "empty"
        url_data["headers"]["Sec-Fetch-Mode"] = "cors"
        url_data["headers"]["Sec-Fetch-Site"] = "same-site"
      end
      table.insert(urls, url_data)
      addedtolist[key] = true
      if not body_data then
        addedtolist[url_] = true
        addedtolist[url] = true
      end
      return true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    newurl = string.gsub(newurl, " ", "%%20")
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function ajax_parameters()
    local parameters = "&_=" .. tostring(context["ajax_count"])
    context["ajax_count"] = context["ajax_count"] + 1
    if item_type == "user" then
      context["trace_count"] = context["trace_count"] + 1
      parameters = parameters .. "&_traceId=" .. context["trace_id"] .. ":" .. tostring(context["trace_count"])
    end
    if context["csrf_token"] and context["csrf_token"] ~= "" then
      parameters = parameters .. "&c_tk=" .. urlparse.escape(context["csrf_token"])
    end
    return parameters
  end

  local function flatten_json(data)
    local result = ""
    for key, value in pairs(data) do
      if key == "uidCrypt"
        and type(value) == "string" then
        check("https://wenwen.sogou.com/user/center?uid=" .. urlparse.escape(value))
      elseif key == "tagId" then
        check("https://wenwen.sogou.com/cate/tag?tagId=" .. urlparse.escape(tostring(value)))
      end
      if type(value) == "table" then
        if key == "tagIds" then
          for _, tag in pairs(value) do
            check("https://wenwen.sogou.com/cate/tag?tagId=" .. urlparse.escape(tostring(tag)))
          end
        end
        result = result .. " " .. flatten_json(value)
      elseif type(value) == "string" then
        result = result .. " " .. value .. " \"" .. value .. "\""
      end
    end
    return result
  end

  if allowed(url) and status_code < 300 then
    if item_type == "media" then
      if string.match(url, "^https?://img%.sogoucdn%.com/v2/thumb/%?") then
        local source = string.match(url, "[%?&]url=([^&]+)")
        if source then
          check(urlparse.unescape(source))
        end
      end
      if string.match(content_type, "text/css")
        or string.match(content_type, "javascript") then
        html = read_file(file)
      end
    else
      html = read_file(file)
      if string.match(url, "^https?://wenwenfeedapi%.sogou%.com/sgapi/related/")
        or string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/user%-info%?")
        or string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/user%-badge%?") then
        html = html .. "\n" .. flatten_json(cjson.decode(html))
        if string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/user%-info%?") then
          check(
            "https://wenwen.sogou.com/wapi/ms/user-badge"
              .. "?uid=" .. urlparse.escape(urlparse.unescape(item_value))
              .. "&ta=" .. urlparse.escape(context["ta"])
              .. ajax_parameters()
          )
        elseif string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/user%-badge%?") then
          history_start = 0
        end
      elseif string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/comments%?") then
        local ansid = string.match(url, "[%?&]ansid=([0-9]+)")
        local start = tonumber(string.match(url, "[%?&]start=([0-9]+)"))
        local json = cjson.decode(html)
        for _, comment in ipairs(json) do
          context["comments"][ansid]["ids"][comment["idStr"]] = start
        end
        if start == context["comments"][ansid]["total"] then
          context["comments"][ansid]["end_seen"] = true
        end
        html = html .. "\n" .. flatten_json(json)
      elseif string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/question%-commonlist%?") then
        local start = tonumber(string.match(url, "[%?&]start=([0-9]+)"))
        local limit = tonumber(string.match(url, "[%?&]limit=([0-9]+)"))
        local json = cjson.decode(html)
        for _, answer in ipairs(json) do
          local previous = context["api_answers"][answer["idStr"]]
          context["api_answers"][answer["idStr"]] = {
            ["start"]=start,
            ["comment_total"]=math.max(
              (previous and previous["comment_total"]) or 0,
              answer["commentNum"]
            )
          }
        end
        if #json < limit then
          context["api_end"] = start + #json
        end
        if not context["answer_total"] then
          context["api_totals"][start] = #json
          context["entry_url"] = "https://wenwen.sogou.com/question/q" .. item_value .. ".htm"
          check(context["entry_url"])
        end
        html = html .. "\n" .. flatten_json(json)
      elseif string.match(url, "^https?://wenwen%.sogou%.com/wapi/ms/my%-list%?") then
        local json = cjson.decode(html)
        local start = tonumber(string.match(url, "[%?&]start=([0-9]+)"))
        if context["history_total"] == nil then
          context["history_total"] = json["total"]
        end
        history_start = start + 20
        if json["questions"] ~= cjson.null then
          for _, question in ipairs(json["questions"]) do
            context["history"][question["idStr"]] = start
            check("https://wenwen.sogou.com/question/q" .. question["idStr"] .. ".htm")
          end
        end
        html = html .. "\n" .. flatten_json(json)
      elseif item_type == "question" then
        if not context["related_queued"] then
          context["related_queued"] = true
          check(
            "https://wenwenfeedapi.sogou.com/sgapi/related/hint"
              .. "?app=wenwen"
              .. "&orig=web"
              .. "&key=" .. context["title"]
              .. ajax_parameters()
          )
          check(
            "https://wenwenfeedapi.sogou.com/sgapi/related/question"
              .. "?qid=" .. item_value
              .. "&key=" .. context["title"]
              .. "&len=5"
              .. ajax_parameters()
          )
        end
        local pg = tonumber(string.match(url, "[%?&]pg=([0-9]+)")) or 0
        for ans_id in string.gmatch(html, "id=\"ans_([0-9]+)\"") do
          context["html_answers"][ans_id] = pg
        end
        for data_num, answer in string.gmatch(html, "class=\"btn%-comment get_comment\" data%-num=\"([0-9]+)\"[^>]*>.-class=\"comment_num_([0-9]+)\"") do
          if not context["comments"][answer] then
            data_num = tonumber(data_num)
            context["comments"][answer] = {
              total=data_num,
              ids={}
            }
            local start = 0
            while data_num > 0 and start <= data_num do
              local count = (start == 0 and 3) or 5
              check(
                "https://wenwen.sogou.com/wapi/ms/comments"
                  .. "?ansid=" .. answer
                  .. "&questionId=" .. item_value
                  .. "&start=" .. tostring(start)
                  .. "&len=" .. tostring(count)
                  .. ajax_parameters(),
                nil, url
              )
              start = start + count
            end
          end
        end
        for start = 0, context["answer_total"], 20 do
          if not context["api_totals"][start]
            or context["api_totals"][start] < math.min(20, context["answer_total"]) then
            context["api_totals"][start] = context["answer_total"]
            check(
              "https://wenwen.sogou.com/wapi/ms/question-commonlist"
                .. "?start=" .. tostring(start)
                .. "&limit=20"
                .. "&qid=" .. item_value
                .. "&orig=254"
                .. ajax_parameters(),
              nil, url
            )
          end
        end
        if context["answer_total"] > 5 then
          for page = 1, math.ceil(context["answer_total"] / 5) do
            check("https://wenwen.sogou.com/question/q" .. item_value .. ".htm?pg=" .. tostring(page))
          end
        end
      elseif item_type == "user" and context["trace_id"] == nil then
        context["trace_id"] = cjson.decode(string.match(html, "for%(var key in ({[^\n]+})%)"))["traceId"]
        context["ta"] = urlparse.unescape(string.match(url, "[%?&]ta=([^&]+)") or "")
        check(
          "https://wenwen.sogou.com/wapi/ms/user-info"
            .. "?uid=" .. urlparse.escape(urlparse.unescape(item_value))
            .. ajax_parameters()
        )
      end
    end

    if history_start
      and history_start < (context["history_total"] or 1) then
      check(
        "https://wenwen.sogou.com/wapi/ms/my-list"
          .. "?tp=20"
          .. "&start=" .. tostring(history_start)
          .. "&len=20"
          .. "&uid=" .. urlparse.escape(urlparse.unescape(item_value))
          .. "&ta=" .. urlparse.escape(context["ta"])
          .. ajax_parameters()
      )
    end

    if html then
      for quote, quoted in pairs({
        ["\""]=string.gsub(html, "&[qQ][uU][oO][tT];", "\""),
        ["'"]=string.gsub(html, "&#039;", "'")
      }) do
        local pattern = "%s[sS][rR][cC][sS][eE][tT]%s*=%s*" .. quote .. "([^" .. quote .. "]+)" .. quote
        for srcset in string.gmatch(quoted, pattern) do
          for newurl in string.gmatch(srcset, "([^,%s]+)[^,]*") do
            checknewurl(newurl)
            checknewshorturl(newurl)
          end
        end
        quoted = string.gsub(quoted, pattern, "")
        for newurl in string.gmatch(quoted, "([^" .. quote .. "]+)") do
          checknewurl(newurl)
        end
        for _, attribute in pairs({"href", "src", "data-src"}) do
          for newurl in string.gmatch(html, "[^%-]" .. string.gsub(attribute, "%-", "%%-") .. "=" .. quote .. "([^" .. quote .. "]+)" .. quote) do
            checknewshorturl(newurl)
          end
        end
      end
      for newurl in string.gmatch(html, "url%(%s*(.-)%s*%)") do
        newurl = string.gsub(html_entities.decode(newurl), "^[\"'](.-)[\"']$", "%1")
        checknewurl(newurl)
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, "<link>(.-)</link>") do
        check(string.match(newurl, "^%s*<!%[CDATA%[(.-)%]%]>%s*$") or newurl)
      end
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  local headers = http_stat["response_headers"]["headers"]
  status_code = http_stat["statcode"]
  content_type = (headers["content-type"] and string.lower(headers["content-type"][1])) or ""
  set_item(url["url"])

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()

  logged_response = true
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    print("Not writing to WARC.")
    return false
  end

  if http_stat["res"] < 0 then
    return false
  end

  if not (
    status_code == 200
    or status_code == 301
    or status_code == 302
    or (
      status_code == 404
      and item_type == "media"
      and string.match(url["url"], "^https?://cache%.soso%.com/qlogo/g%?")
    )
  ) then
    retry_url = true
    return false
  end

  -- a ton of checks are done here, since the website behaves very unstable when
  -- it comes to returning correct content.

  if status_code == 200
    or status_code == 404 then
    if (http_stat["contlen"] >= 0 and http_stat["len"] ~= http_stat["contlen"])
      or http_stat["len"] == 0 then
      retry_url = true
      return false
    end
    if item_type ~= "media" then
      local html = read_file(http_stat["local_file"])
      local related = string.match(url["url"], "^https?://wenwenfeedapi%.sogou%.com/sgapi/related/([a-z]+)%?")
      if related then
        if not string.match(html, "^%s*{") then
          retry_url = true
          return false
        end
        local json = cjson.decode(html)
        if json["code"] ~= 200
          or type(json["data"]) ~= "table"
          or #json["data"] == 0 then
          retry_url = true
          return false
        end
        for _, entry in ipairs(json["data"]) do
          if related == "question" then
            if type(entry["id"]) ~= "string"
              or not string.match(entry["id"], "^[0-9]+$")
              or not string.match(entry["title"], "[^%s]+")
              or not string.match(entry["url"], "^https?://wenwen%.sogou%.com/z/q" .. entry["id"] .. "%.htm$") then
              retry_url = true
              return false
            end
          elseif related ~= "hint"
            or type(entry) ~= "string"
            or not string.match(entry, "[^%s]+") then
            retry_url = true
            return false
          end
        end
      elseif string.match(url["url"], "^https?://wenwen%.sogou%.com/wapi/ms/question%-commonlist%?") then
        if not string.match(html, "^%s*%[") then
          retry_url = true
          return false
        end
        local start = tonumber(string.match(url["url"], "[%?&]start=([0-9]+)"))
        local limit = tonumber(string.match(url["url"], "[%?&]limit=([0-9]+)"))
        local json = cjson.decode(html)
        if #json > limit
          or #json < math.min(limit, math.max((context["answer_total"] or 0) - start, 0)) then
          retry_url = true
          return false
        end
        local seen = {}
        for _, answer in ipairs(json) do
          local rich_content = answer["richContent"]
          if not rich_content
            or rich_content == cjson.null
            or rich_content == "" then
            rich_content = answer["content"]
          end
          local previous = context["api_answers"][answer["idStr"]]
          if previous then
            previous = previous["start"]
          end
          if type(answer["idStr"]) ~= "string"
            or not string.match(answer["idStr"], "^[0-9]+$")
            or answer["commentNum"] < 0
            or answer["commentNum"] % 1 ~= 0
            or context["best_answers"][answer["idStr"]]
            or seen[answer["idStr"]]
            or (
              previous
              and previous ~= start
              and context["api_totals"][previous] ~= previous
              and (
                context["api_totals"][start] ~= start
                or start >= context["answer_total"]
              )
            )
            or not (
              (type(rich_content) == "string" and string.match(rich_content, "[^%s]+"))
              or (type(answer["pics"]) == "table" and #answer["pics"] > 0)
            ) then
            retry_url = true
            return false
          end
          seen[answer["idStr"]] = true
        end
      elseif string.match(url["url"], "^https?://wenwen%.sogou%.com/wapi/ms/comments%?") then
        if not string.match(html, "^%s*%[") then
          retry_url = true
          return false
        end
        local ansid = string.match(url["url"], "[%?&]ansid=([0-9]+)")
        local start = tonumber(string.match(url["url"], "[%?&]start=([0-9]+)"))
        local len = tonumber(string.match(url["url"], "[%?&]len=([0-9]+)"))
        local json = cjson.decode(html)
        local expected = math.min(len, context["comments"][ansid]["total"] - start)
        local seen = {}
        for _, comment in ipairs(json) do
          if type(comment["idStr"]) ~= "string"
            or not string.match(comment["idStr"], "^[0-9]+$")
            or not string.match(comment["content"], "[^%s]+")
            or seen[comment["idStr"]]
            or (
              context["comments"][ansid]["ids"][comment["idStr"]]
              and context["comments"][ansid]["ids"][comment["idStr"]] ~= start
            ) then
            retry_url = true
            return false
          end
          seen[comment["idStr"]] = true
        end
        if #json ~= expected then
          if #json > expected then
            context["counts_changed"] = true
          end
          retry_url = true
          return false
        end
      elseif string.match(url["url"], "^https?://wenwen%.sogou%.com/wapi/ms/user%-info%?") then
        if not string.match(html, "^%s*{") then
          retry_url = true
          return false
        end
        local json = cjson.decode(html)
        if json["uidCrypt"] ~= urlparse.unescape(item_value)
          or type(json["name"]) ~= "string"
          or not string.match(json["name"], "[^%s]+")
          or type(json["pic"]) ~= "string"
          or not string.match(json["pic"], "[^%s]+") then
          retry_url = true
          return false
        end
        context["user_info"] = true
      elseif string.match(url["url"], "^https?://wenwen%.sogou%.com/wapi/ms/user%-badge%?") then
        if not string.match(html, "^%s*{") then
          retry_url = true
          return false
        end
        local json = cjson.decode(html)
        for _, key in pairs({
          "activityBadges",
          "privilegeBadges",
          "darenAdoptBadges",
          "answerNumBadges",
          "answerDayBadges"
        }) do
          if type(json[key]) ~= "table" then
            retry_url = true
            return false
          end
          for _, badge in pairs(json[key]) do
            if badge["id"] < 0
              or badge["id"] % 1 ~= 0
              or type(badge["name"]) ~= "string"
              or not string.match(badge["name"], "[^%s]+")
              or type(badge["exist"]) ~= "boolean" then
              retry_url = true
              return false
            end
          end
        end
        context["user_badge"] = true
      elseif string.match(url["url"], "^https?://wenwen%.sogou%.com/wapi/ms/my%-list%?") then
        if not string.match(html, "^%s*{") then
          retry_url = true
          return false
        end
        local json = cjson.decode(html)
        local start = tonumber(string.match(url["url"], "[%?&]start=([0-9]+)"))
        local len = tonumber(string.match(url["url"], "[%?&]len=([0-9]+)"))
        if json["retcode"] ~= 0
          or json["total"] <= 0
          or json["total"] % 1 ~= 0
          or (
            context["history_total"]
            and json["total"] ~= context["history_total"]
          ) then
          retry_url = true
          return false
        end
        if json["total"] > start then
          if type(json["questions"]) ~= "table"
            or #json["questions"] ~= math.min(len, json["total"] - start) then
            retry_url = true
            return false
          end
          local seen = {}
          for _, question in ipairs(json["questions"]) do
            if type(question["idStr"]) ~= "string"
              or not string.match(question["idStr"], "^[0-9]+$")
              or not string.match(question["title"], "[^%s]+")
              or seen[question["idStr"]]
              or (
                context["history"][question["idStr"]]
                and context["history"][question["idStr"]] ~= start
              ) then
              retry_url = true
              return false
            end
            seen[question["idStr"]] = true
          end
        elseif json["questions"] ~= cjson.null
          and next(json["questions"]) ~= nil then
          retry_url = true
          return false
        end
      else
        local data = string.match(html, "for%(var key in ({[^\n]+})%)")
        if not data
          or not string.match(html, "</html>%s*$") then
          retry_url = true
          return false
        end
        data = cjson.decode(data)
        if item_type == "question" then
          local answers = {}
          local pg = tonumber(string.match(url["url"], "[%?&]pg=([0-9]+)")) or 0
          local best_answers = {}
          local best_html = string.match(html, "id=\"bestAnswers\"(.*)")
          if best_html then
            best_html = string.match(best_html, "^(.-)class=\"replay%-wrap common_answers") or best_html
            for ans_id in string.gmatch(best_html, "id=\"ans_([0-9]+)\"") do
              best_answers[ans_id] = true
            end
          end
          for ans_id in string.gmatch(html, "id=\"ans_([0-9]+)\"") do
            if answers[ans_id]
              or (
                not best_answers[ans_id]
                and context["html_answers"][ans_id]
                and context["html_answers"][ans_id] ~= pg
              ) then
              retry_url = true
              return false
            end
            answers[ans_id] = true
          end
          local count = get_count(answers)
          if data["notFoundQuestion"] ~= false
            or data["id"] ~= item_value
            or not string.match(html, "id=\"question_title_val\">%s*[^<%s]")
            or data["answerTotal"] ~= count then
            retry_url = true
            return false
          end
          local best = get_count(best_answers)
          if data["hasbestAnswer"] ~= (best > 0) then
            retry_url = true
            return false
          end
          local answer_total = tonumber(string.match(html, "class=\"replay%-wrap common_answers\">.-class=\"section%-tit\">[^<]+<span>%(([0-9]+)[^<]*%)</span>"))
          if answer_total == nil then
            if count ~= best then
              retry_url = true
              return false
            end
            answer_total = 0
          end
          -- the site is odd with serving comments, varying numbers of comments
          -- per page, make sure to retrieve up to a page with zero comments.
          local ending = context["answer_total"]
            and context["answer_total"] >= 5
            and pg == math.ceil(math.max(context["answer_total"], answer_total) / 5)
          if ending and answer_total == 0 and count == best then
            answer_total = context["answer_total"]
          end
          if count > 5 + best
            or answer_total < get_count(context["api_answers"])
            or (
              (pg > 0 or answer_total > 5)
              and count > best
              and not string.match(html, "class=\"page%-num page_wrap\"")
            )
            or (
              ending
              and count ~= best
            )
            or (
              not ending
              and (
                answer_total > 0
                or (
                  context["answer_total"]
                  and context["answer_total"] > 0
                )
              )
              and count == best
            )
            or (
              answer_total == 0
              and count ~= best
            ) then
            retry_url = true
            return false
          end
          local comments = {}
          for data_num, answer in string.gmatch(html, "class=\"btn%-comment get_comment\" data%-num=\"([0-9]+)\"[^>]*>.-class=\"comment_num_([0-9]+)\"") do
            if not answers[answer]
              or comments[answer]
              or (
                context["comments"][answer]
                and context["comments"][answer]["total"] ~= tonumber(data_num)
              ) then
              retry_url = true
              return false
            end
            comments[answer] = true
          end
          if get_count(comments) ~= count then
            retry_url = true
            return false
          end
          if context["answer_total"] and context["answer_total"] ~= answer_total then
            context["counts_changed"] = true
          end
          context["answer_total"] = math.max(context["answer_total"] or 0, answer_total)
          for ans_id in pairs(best_answers) do
            context["best_answers"][ans_id] = true
          end
          if ending then
            context["ending_page"] = pg
          end
          context["title"] = data["title"]
          not_found_count = 0
        elseif item_type == "user" then
          if data["mineCrypt"] ~= item_value
            or not string.match(html, "id=\"userList_answer\"") then
            retry_url = true
            return false
          end
        end
        context["csrf_token"] = data["csrfToken"]
        context["content_seen"] = true
      end
    else
      local file = assert(io.open(http_stat["local_file"], "rb"))
      local data = string.lower(file:read(1024))
      file:close()
      if status_code == 404 then
        if not string.match(data, "<code>nosuchkey</code>")
          or not string.match(data, "<resource>/qlogo/g</resource>")
          or not string.match(data, "</error>%s*$") then
          retry_url = true
          return false
        end
      elseif string.match(data, "<html")
        or string.match(data, "forbidden") then
        retry_url = true
        return false
      end
      context["content_seen"] = true
    end
  end

  if status_code >= 300 and status_code <= 399 then
    if not http_stat["newloc"] then
      retry_url = true
      return false
    end
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if string.match(newloc, "^https?://wenwen%.sogou%.com/notFound")
      or string.match(newloc, "^https?://wenwen%.sogou%.com/question/notFound") then
      if context["content_seen"]
        or tries > 0
        or (context["api_answers"] and next(context["api_answers"]))
        or context["entry_url"] ~= url["url"] then
        retry_url = true
      else
        not_found_count = not_found_count + 1
        abort_item()
      end
      return false
    end
    if string.match(newloc, "[%s\\\"]") or not string.match(newloc, "^https?://") then
      retry_url = true
      return false
    end
  end

  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
    retry_url = true
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    if not_found_count >= 3 then
      print("sleeping 70 seconds after many notfound redirects.")
      os.execute("sleep 60")
      not_found_count = 0
    end
    return wget.actions.EXIT
  end

  local newloc = nil
  if status_code >= 300 and status_code <= 399 then
    if http_stat["newloc"] then
      newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    end
  end

  if status_code == 0 or http_stat["res"] < 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 7
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    downloaded[url["url"]] = true
  end

  if newloc then
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  finish_item()
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = https.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["sogouwenwen-e4fe45b303a7676b"] = discovered_items,
    ["sogouwenwen-stash-tag-b97a780bb064ba91?shard=stash"] = discovered_stash,
    ["urls-8adf801e69ddf611"] = discovered_outlinks
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end
