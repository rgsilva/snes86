public class Sieve {
    static int pass() {
        boolean[] flags = new boolean[8191];
        for (int i = 0; i < 8191; i++) flags[i] = true;
        int count = 0;
        for (int i = 0; i < 8191; i++) {
            if (flags[i]) {
                int prime = i + i + 3;
                for (int k = i + prime; k < 8191; k += prime) flags[k] = false;
                count++;
            }
        }
        return count;
    }
    public static void main(String[] args) throws Exception {
        System.out.println("BYTE Sieve, 1 pass");
        System.out.println(pass());
    }
}
