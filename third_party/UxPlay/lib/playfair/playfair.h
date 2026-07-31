#ifndef PLAYFAIR_H
#define PLAYFAIR_H

void playfair_decrypt(unsigned char* message3, unsigned char* cipherText, unsigned char* keyOut);
void playfair_session_key(unsigned char* message3, unsigned char* keyOut);

#endif
