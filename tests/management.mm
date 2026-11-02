#include "../native/Management.hpp"
#include <iostream>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 1) { fprintf(stderr, "Invalid management test arguments\n"); return 1; }
        std::string input;
        if (!std::getline(std::cin, input) || input.size() > management::maxPacket) {
            fprintf(stderr, "Invalid management test input\n"); return 1;
        }
        NSData *data = [NSData dataWithBytes:input.data() length:input.size()];
        NSError *error = nil;
        id body = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![body isKindOfClass:NSDictionary.class]) {
            fprintf(stderr, "Invalid management test JSON\n"); return 1;
        }
        NSDictionary *reply = management::request(body, &error);
        if (!reply) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        NSData *output = [NSJSONSerialization dataWithJSONObject:reply options:0 error:&error];
        if (!output) { fprintf(stderr, "Invalid management response\n"); return 1; }
        fwrite(output.bytes, 1, output.length, stdout);
        putchar('\n');
        return reply[@"error"] ? 2 : 0;
    }
}
