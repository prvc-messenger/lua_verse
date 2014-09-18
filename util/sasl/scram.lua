
local base64, unbase64 = require "mime".b64, require"mime".unb64;
local crypto = require"crypto";
local bit = require"bit";

local XOR, H, HMAC, Hi;
local tonumber = tonumber;
local char, byte = string.char, string.byte;
local gsub = string.gsub;
local xor = bit.bxor;

function XOR(a, b)
	return (gsub(a, "()(.)", function(i, c)
		return char(xor(byte(c), byte(b, i)))
	end));
end

function H(str)
	return crypto.digest("sha1", str, true);
end

function HMAC(key, str)
	return crypto.hmac.digest("sha1", str, key, true);
end

function Hi(str, salt, i)
	local U = HMAC(str, salt .. "\0\0\0\1");
	local ret = U;
	for _ = 2, i do
		U = HMAC(str, U);
		ret = XOR(ret, U);
	end
	return ret;
end

-- assert(Hi("password", "salt", 1) == string.char(0x0c, 0x60, 0xc8, 0x0f, 0x96, 0x1f, 0x0e, 0x71, 0xf3, 0xa9, 0xb5, 0x24, 0xaf, 0x60, 0x12, 0x06, 0x2f, 0xe0, 0x37, 0xa6));
-- assert(Hi("password", "salt", 2) == string.char(0xea, 0x6c, 0x01, 0x4d, 0xc7, 0x2d, 0x6f, 0x8c, 0xcd, 0x1e, 0xd9, 0x2a, 0xce, 0x1d, 0x41, 0xf0, 0xd8, 0xde, 0x89, 0x57));

local function Normalize(str)
	return str; -- TODO
end

local function value_safe(str)
	return (gsub(str, "[,=]", { [","] = "=2C", ["="] = "=3D" }));
end

local function scram(stream, name)
	local username = "n=" .. value_safe(stream.username);
	local c_nonce = base64(crypto.rand.bytes(15));
	local nonce = "r=" .. c_nonce;
	local client_first_message_bare = username .. "," .. nonce;
	local cbind_data = "";
	local gs2_cbind_flag = "y";
	if name == "SCRAM-SHA-1-PLUS" then
		cbind_data = stream.conn:socket():getfinished();
		gs2_cbind_flag = "p=tls-unique";
	end
	local gs2_header = gs2_cbind_flag .. ",,";
	local client_first_message = gs2_header .. client_first_message_bare;
	local cont, server_first_message = coroutine.yield(client_first_message);
	if cont ~= "challenge" then return false end

	local salt, iteration_count;
	nonce, salt, iteration_count = server_first_message:match("(r=[^,]+),s=([^,]*),i=(%d+)");
	local i = tonumber(iteration_count);
	salt = unbase64(salt);
	if not nonce or not salt or not i then
		return false, "Could not parse server_first_message";
	elseif nonce:find(c_nonce, 3, true) ~= 3 then
		return false, "nonce sent by server does not match our nonce";
	elseif nonce == c_nonce then
		return false, "server did not append s-nonce to nonce";
	end

	local cbind_input = gs2_header .. cbind_data;
	local channel_binding = "c=" .. base64(cbind_input);
	local client_final_message_without_proof = channel_binding .. "," .. nonce;

	local SaltedPassword  = Hi(Normalize(stream.password), salt, i);
	local ClientKey       = HMAC(SaltedPassword, "Client Key");
	local StoredKey       = H(ClientKey);
	local AuthMessage     = client_first_message_bare .. "," ..  server_first_message .. "," ..  client_final_message_without_proof;
	local ClientSignature = HMAC(StoredKey, AuthMessage);
	local ClientProof     = XOR(ClientKey, ClientSignature);
	local ServerKey       = HMAC(SaltedPassword, "Server Key");
	local ServerSignature = HMAC(ServerKey, AuthMessage);

	local proof = "p=" .. base64(ClientProof);
	local client_final_message = client_final_message_without_proof .. "," .. proof;

	local ok, server_final_message = coroutine.yield(client_final_message);
	if ok ~= "success" then return false, "success-expected" end

	local verifier = server_final_message:match("v=([^,]+)");
	if unbase64(verifier) ~= ServerSignature then
		return false, "server signature did not match";
	end
	return true;
end

return function (stream, mechanisms, preference, supported)
	if stream.username and (stream.password or (stream.client_key or stream.server_key)) then
		mechanisms["SCRAM-SHA-1"] = scram;
		preference["SCRAM-SHA-1"] = 99;
		local sock = stream.conn:ssl() and stream.conn:socket();
		if sock and sock.getfinished then
			mechanisms["SCRAM-SHA-1-PLUS"] = scram;
			preference["SCRAM-SHA-1-PLUS"] = 100
		end
	end
end