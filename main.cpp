#include <print>
#include <filesystem>

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

int 
main(int argc, char **argv)
{
	if (auto pConnection = virConnectOpen("qemu:///system"
	); auto pDomain = virDomainLookupByName(pConnection, "win11-24h2"))
	{
		auto socketName = std::format(
			"/run/libvirt/qemu/channel/{}-{}/org.qemu.guest_agent.0",
			virDomainGetID(pDomain),
			virDomainGetName(pDomain)
		);
		sockaddr_un addr{};
		addr.sun_family = AF_UNIX;
		std::strncpy(
			addr.sun_path,
			socketName.c_str(),
			sizeof(addr.sun_path) - 1
		);
		
		if (int dataSocket = socket(AF_UNIX, SOCK_STREAM, 0
		); dataSocket != -1)
		{
			if (int ret = connect(
				dataSocket, (sockaddr *)&addr, sizeof(addr)
			); ret == -1)
			{
				perror("connect");
				return errno;
			}
			close(dataSocket);
		}
	}
	return 0;
}
