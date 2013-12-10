local db = require "luci.commotion.debugger"
local http = require "luci.http"
local cdisp = require "luci.commotion.dispatch"

local m = Map("wireless", translate("Passwords"), translate("Commotion basic security settings places all the passwords and other security features in one place for quick configuration. "))

--redirect on saved and changed to check changes.
m.on_after_save = cdisp.conf_page

--PASSWORDS
local v0 = true -- track password success across maps

-- CURRENT PASSWORD
-- Allow incorrect root password to prevent settings change
-- Don't prompt for password if none has been set
if luci.sys.user.getpasswd("root") then
   s0 = m:section(TypedSection, "_dummy", translate("Current Password"), translate("Current password required to make changes on this page"))
   s0.addremove = false
   s0.anonymous = true
   pw0 = s0:option(Value, "_pw0")
   pw0.password = true
   -- fail by default
   v0 = false
   function s0.cfgsections()
	  return { "_pass0" }
   end
end

local interfaces = {}
uci.foreach("wireless", "wifi-iface",
			function(s)
			   local name = s[".name"]
			   local key = s.key or "NONE"
			   local mode = s.mode or "NONE"
			   local enc = s.encryption or "NONE"
			   table.insert(interfaces, {name=name, mode=mode, key=key, enc=enc})
			end
)

--iface password creator for all other interfaces
--! @name pw_sec_opt
--! @brief create password options to add to interface passed-
function pw_sec_opt(pw_s, iface)
   --section options
   pw_s.addremove = false
   pw_s.anonymous = true
   
   --encryption toggle
   enc = pw_s:option(Flag, "encryption", translate("Require a Password?"), translate("When people connect to this access point, should a password be required?"))
   enc.disabled = "none"
   enc.enabled = "psk2"
   enc.rmempty = true
   enc.default = enc.disabled --default must == disabled value for rmempty to work
   
   --Make enc flag actually check for section.changed and set that flag for the confirmation page to work
   --TODO make this a commotion function. It is repeated in multiple cbi models.
   function enc.remove(self, section)
	  value = self.map:get(section, self.option)
	  if value ~= self.disabled then
		 local key = self.map:del(section, "key")
		 local enc = self.map:del(section, self.option)
		 self.section.changed = true
		 return key and enc or false
	  end
   end
   
   function enc.write(self, section, fvalue)
	  value = self.map:get(section, self.option)
	  if value ~= fvalue then
		 self.section.changed = true
		 return self.map:set(section, self.option, fvalue)
	  end
   end
   
   --password options
   pw1 = pw_s:option(Value, (iface.name.."_pass1"))
   pw1.password = true
   pw1.anonymous = true
   pw1:depends("encryption", "psk2")
   --confirmation password
   pw2 = pw_s:option(Value, iface.name.."_pass2", nil, translate("Confirm Password"))
   pw2.password = true
   pw2.anonymous = true
   pw2:depends("encryption", "psk2")
   
   --password should write to the key, not to the dummy value
   function pw1.write(self, section, value)
	  return self.map:set(section, "key", value)
   end
   
   function pw2.write() return true end
   
   --make sure passwords are equal
   function pw1.validate(self, value, section)
	  local v1 = value
	  local v2 = pw2:formvalue(section)
	  --local v2 = http.formvalue(string.gsub(self:cbid(section), "%d$", "2"))
	  if v1 and v2 and #v1 > 0 and #v2 > 0 then
		 if v1 == v2 then
			if m.message == nil then
			   m.message = translate("Password successfully changed!")
			end
			return value
		 else
			m.message = translate("Error, no changes saved. See below.")
			self:add_error(section, translate("Given password confirmation did not match, password not changed!"))
			return nil
		 end
	  else
		 m.message = translate("Error, no changes saved. See below.")
		 self:add_error(section, translate("Unknown Error, password not changed!"))
		 return nil
	  end
   end
end

--MESH ECRYPTION PASSWORD
--Check for mesh interfaces
mesh_ifaces = {}
for i,iface in ipairs(interfaces) do
   if iface.mode == "adhoc" then
	  table.insert(mesh_ifaces, iface)
   end
end

local pw_text = "To encrypt Commotion mesh network data between devices, each device must share a common mesh encryption password. Enter that shared password here."
if #mesh_ifaces > 1 then
   for _,x in pairs(mesh_ifaces) do
	  local meshPW = m:section(NamedSection, x.name, "wifi-iface", x.name, pw_text)
	  meshPW = pw_sec_opt(meshPW, x)
   end
else
   db.log("mesh ifaces")
   db.log(mesh_ifaces[1].name)
   local meshPW = m:section(NamedSection, mesh_ifaces[1].name, "wifi-iface", mesh_ifaces[1].name, pw_text)
   meshPW = pw_sec_opt(meshPW, mesh_ifaces[1])
end

--ADMIN PASSWORD
admin_pw_text = "This password is used to login to this node."
admin_pw_s = m:section(TypedSection,"_dummy", translate("Administration Password"), translate(admin_pw_text))
admin_pw_s.addremove = false
admin_pw_s.anonymous = true

admin_pw1 = admin_pw_s:option(Value, "admin_pw1")
admin_pw1.password = true

admin_pw2 = admin_pw_s:option(Value, "admin_pw2", nil, translate("Confirm Password"))
admin_pw2.password = true

function admin_pw_s.cfgsections()
	return { "_pass" }
end

--Check for other Interfaces
for i,iface in ipairs(interfaces) do
   if iface.mode ~= "adhoc" then
	  local otherPW = m:section(NamedSection, iface.name, "wifi-iface", iface.name.." Interface", translate("Enter the password people should use to connect to this interface."))
	  otherPW = pw_sec_opt(otherPW, iface, iface.name)
   end
end

--!brief This map checks for the admin password field and denies all saving and removes the confirmation page redirect if it is there.
function m.on_parse(map)
   local form = http.formvaluetable("cbid.wireless")
   local check = nil
   local conf_pass = nil
   for field,val in pairs(form) do
	  string.gsub(field, ".-_pw(%d)$",
				  function(num)
					 if tonumber(num) == 0 then
						conf_pass = val
					 end
					 if val then
						check = true
					 end
				  end)
   end
   if check ~= nil then
	  if conf_pass then
		 v0 = luci.sys.user.checkpasswd("root", conf_pass)
		 if v0 ~= true then
			m.message = translate("Incorrect password. Changes rejected!")
			m.save = false
			function m.on_after_save() return true end --Don't redirect on error
		 end
	  else
		 m.message = translate("Please enter your old password. Changes rejected!")
		 m.save = false
	  end
   end
end

function m.on_save(self)
   local v1 = pw1:formvalue("_pass")
   local v2 = pw2:formvalue("_pass")
   if v0 == true and v1 and v2 and #v1 > 0 and #v2 > 0 then
	  if v1 == v2 then
		 if luci.sys.user.setpasswd(luci.dispatcher.context.authuser, v1) == 0 then
			--TODO WAIT @critzo/@georgiamoon decide upon administration password experience for confirmation page.
--			eg. function m.on_after_save() return true end --Don't redirect on admin pw success as it is not a uci value and shows up as nil.
			m.message = translate("Admin Password successfully changed!")
		 else
			m.message = translate("Unknown Error, password not changed!")
		 end
	  else
		 m.message = translate("Given password confirmation did not match, password not changed!")
	  end
   end
end

return m



