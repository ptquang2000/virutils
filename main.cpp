#include <print>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <libvirt/libvirt.h>

#include "third_party/json.h"
#include "third_party/tinyxml2.cpp"


#define i8	int8_t
#define i16	int16_t
#define i32	int32_t
#define i64	int64_t

#define u8	uint8_t
#define u16	uint16_t
#define u32	uint32_t
#define u64	uint64_t

static constexpr std::string_view k_domainName =  "win11-tiny";
static constexpr std::string_view k_socketFormat = 
"/run/libvirt/qemu/channel/{}-{}/org.qemu.guest_agent.0";

int 
main(int argc, char **argv)
{
	if (auto pConnection = virConnectOpen("qemu:///system"
	); auto pDomain = virDomainLookupByName(
		pConnection, k_domainName.data()))
	{
		auto socketName = std::format(
			k_socketFormat.data(),
			virDomainGetID(pDomain),
			virDomainGetName(pDomain));
		sockaddr_un addr{};
		addr.sun_family = AF_UNIX;
		std::strncpy(
			addr.sun_path,
			socketName.c_str(),
			sizeof(addr.sun_path) - 1);
		
		if (int dataSocket = socket(AF_UNIX, SOCK_STREAM, 0
		); dataSocket != -1)
		{
			if (int ret = connect(
				dataSocket, 
				reinterpret_cast<sockaddr *>(&addr),
				sizeof(addr)
			); ret == -1)
			{
				perror("Failed to connect socket");
				return errno;
			}

			nlohmann::json guestExecCommand
			{
				{"execute", "guest-exec"},
				{"arguments", {
						{"path", "/bin/sh"},
						{"arg", {"-c", "id"}},
						{"capture-output", true}
				}}
			};
			auto request = guestExecCommand.dump() + '\n';
			auto command = std::string_view(request);
			while (!command.empty())
			{
				if (size_t written = write(dataSocket, 
							command.data(), 
							command.size()
				); written > 0)
				{
					command.remove_prefix(written);
				}
				else
				{
					perror("Failed send command");
					return errno;
				}
			}

			std::string buffer(4096, '\0');
			for (;;)
			{
				if (auto end = buffer.find('\n'
				); end != std::string::npos)
				{
					auto line = buffer.substr(0, end);
					buffer.erase(0, end + 1);
					break;
				}
				std::array<char, 4096> chunk;
				ssize_t got = read(dataSocket,
						chunk.data(),
						chunk.size());
				if (got == 0)
				{
					break;
				}
				if (got < 0)
				{
					perror("Failed to read response");
					return {};
				}
				buffer.append(chunk.data(), got);
			}
			close(dataSocket);
		}
	}
	else
	{
		std::println(stderr,
				"Failed to connect domain {}",
				k_domainName);
	}
	return 0;
}
